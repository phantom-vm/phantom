import { call, flushAndStop, runInGuest, serveFile, waitForSave } from "../lib/guest";
import { loadRecipe, resolveAgainstRecipe, RecipeError, type Recipe, type RecipeStep } from "../lib/recipe";
import {
  baseIdentity,
  provenance,
  recordStep,
  sha256,
  sha256File,
  type BuildRecord,
  type RecordedStep,
} from "../lib/record";
import { waitForVMRunning } from "../lib/wait";
import { usageError, type Command } from "../command";

// MARK: - image build (recipe → layered image)
//
//   recipe.yaml → vm.create --fromImage → step → step → … → vm.stop → image.save
//
// Layering onto a finished base image is the everyday build, and the one worth
// declaring: what a toolchain image contains used to live in the flags somebody
// typed that day. Now it lives in a file beside the image, which is also what a
// later reader has to go on.
//
// Building the base itself — IPSW, Setup Assistant over VNC, provisioning — is
// `image build-base` (build-base.ts). Deliberately not the same command: it
// happens once per macOS release, and its middle stage runs in a guest that has
// no agent to run steps in yet.

interface BuildOptions {
  recipePath: string;
  replace: boolean;
  keepVm: boolean;
  dryRun: boolean;
}

function parseArgs(args: string[]): BuildOptions | null {
  const opts: BuildOptions = { recipePath: "", replace: false, keepVm: false, dryRun: false };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-f" || a === "--file") opts.recipePath = args[++i] ?? "";
    else if (a === "--replace") opts.replace = true;
    else if (a === "--keep-vm") opts.keepVm = true;
    else if (a === "--dry-run") opts.dryRun = true;
    // A bare path is the recipe too: `image build recipes/xcode.yaml` is what
    // everyone tries first, and refusing it teaches nothing.
    else if (!a!.startsWith("-") && !opts.recipePath) opts.recipePath = a!;
  }

  return opts.recipePath ? opts : null;
}

export const buildCommand: Command = {
  usage: "-f <recipe.yaml> [options]",
  description: "Build a layered image from a recipe (see docs/authoring-images.md)",
  details: [
    "-f, --file <path>  The recipe. A bare path works too.",
    "--dry-run          Validate the recipe and print the plan; touches no daemon",
    "--replace          Overwrite an existing image of the same name",
    "--keep-vm          Keep the intermediate VM after saving",
  ],
  multiArgHandler: imageBuild,
};

export async function imageBuild(...args: string[]) {
  const opts = parseArgs(args);
  if (!opts) {
    usageError("image", "build", buildCommand);
    process.exit(1);
  }

  try {
    const recipe = await loadRecipe(opts.recipePath);
    if (opts.dryRun) {
      printPlan(recipe, opts);
      return;
    }
    await run(recipe, opts);
  } catch (err) {
    // A recipe error is the user's file, not a build failure — it says where to
    // look and there is nothing to clean up.
    if (err instanceof RecipeError) {
      console.error(`✗ ${err.message}`);
      process.exit(1);
    }
    console.error(`\n✗ Build failed: ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }
}

/// What the recipe resolves to, without doing any of it. The point is to be
/// able to check a recipe — paths, env, order — in a second rather than an hour
/// in, so it deliberately asks the daemon nothing and works with none running.
function printPlan(recipe: Recipe, opts: BuildOptions) {
  console.log(`${recipe.name} — from image '${recipe.from}'${opts.replace ? ", replacing" : ""}`);
  if (recipe.description) console.log(recipe.description);
  console.log(`\n${recipe.steps.length} step${recipe.steps.length === 1 ? "" : "s"}:`);

  for (const [i, step] of recipe.steps.entries()) {
    const what = step.script
      ? `script ${resolveAgainstRecipe(recipe.path, step.script)}`
      : `run ${firstLine(step.run!)}`;
    console.log(`  ${i + 1}. ${step.name} — ${what}`);
    for (const [key, value] of Object.entries(step.env)) {
      console.log(`       ${key}=${value}`);
    }
    if (step.serve) {
      console.log(`       serves ${resolveAgainstRecipe(recipe.path, step.serve)} over the vmnet bridge`);
    }
    console.log(`       up to ${formatDuration(step.timeoutMs)}`);
  }

  console.log(`\nEvery file above exists. Run without --dry-run to build.`);
}

const firstLine = (s: string) => {
  const [head, ...rest] = s.trim().split("\n");
  return rest.length ? `${head} …` : head!;
};

function formatDuration(ms: number): string {
  if (ms % 3600_000 === 0) return `${ms / 3600_000}h`;
  if (ms % 60_000 === 0) return `${ms / 60_000}m`;
  return `${Math.round(ms / 1000)}s`;
}

async function run(recipe: Recipe, opts: BuildOptions) {
  // Create, one line per step, flush+stop, save, delete.
  const total = recipe.steps.length + 4;
  let n = 0;
  const step = (msg: string) => console.log(`\n[${++n}/${total}] ${msg}`);

  // The base has to be here before anything is created — the daemon would
  // answer this at vm.create too, but a build should fail on the recipe's own
  // terms, naming the image the recipe asked for.
  const images = ((await call("image.list")).images ?? []) as { name: string }[];
  if (!images.some((i) => i.name === recipe.from)) {
    throw new Error(
      `base image '${recipe.from}' is not on this Mac — pull it, or build it with 'phantom image build-base'`
    );
  }

  // A restore of a 90GB disk takes minutes; vm.create answers with the vmId
  // right away and decompresses in the background, so nothing is holding a
  // socket open across it. The guest is still booting when the VM reports
  // running, which the waitForAgent on the first step absorbs.
  step(`Creating VM from image '${recipe.from}'`);
  const createRes = await call("vm.create", { fromImage: recipe.from });
  const vmId: string = createRes.vmId;
  await waitForVMRunning(vmId, { onState: (state) => console.log(`    state: ${state}`) });
  console.log(`    VM ${vmId} running`);

  // What actually happened, written into the image at save time: the recipe
  // verbatim, and each step with the sha256 of the script that ran. A path says
  // which file; only the hash says which version of it.
  const recorded: RecordedStep[] = [];
  for (const recipeStep of recipe.steps) {
    step(recipeStep.name);
    const { recorded: entry } = await recordStep(
      {
        name: recipeStep.name,
        script: recipeStep.script,
        sha256: recipeStep.script
          ? await sha256File(resolveAgainstRecipe(recipe.path, recipeStep.script))
          : undefined,
        run: recipeStep.run,
        env: Object.keys(recipeStep.env).length ? recipeStep.env : undefined,
        user: "admin",
        via: "vsock",
      },
      () => runStep(recipe, recipeStep, vmId)
    );
    recorded.push(entry);
  }

  const record: BuildRecord = {
    schemaVersion: 1,
    name: recipe.name,
    description: recipe.description,
    builtAt: new Date().toISOString(),
    ...(await provenance()),
    from: await baseIdentity(recipe.from),
    recipe: {
      path: recipe.path,
      sha256: sha256(recipe.source),
      source: recipe.source,
    },
    steps: recorded,
  };

  step("Flushing disk and stopping VM");
  await flushAndStop(vmId);

  step(`Saving image '${recipe.name}'${opts.replace ? " (replacing)" : ""}`);
  await call("image.save", { vmId, name: recipe.name, replace: opts.replace, build: record }, 60_000);
  await waitForSave(recipe.name);
  console.log(`    image saved`);

  if (opts.keepVm) {
    step(`Keeping intermediate VM ${vmId} (--keep-vm)`);
  } else {
    step(`Deleting intermediate VM ${vmId}`);
    await call("vm.delete", { vmId }, 60_000);
  }

  console.log(`\n✓ Image '${recipe.name}' built from ${recipe.path}`);
}

/// One step: serve its file if it has one, substitute the URL, run the script
/// or the command in the guest.
async function runStep(recipe: Recipe, step: RecipeStep, vmId: string) {
  let server: ReturnType<typeof serveFile> | undefined;
  if (step.serve) {
    const path = resolveAgainstRecipe(recipe.path, step.serve);
    server = serveFile(path);
    console.log(`    serving ${path} to the guest at ${server.url}`);
  }

  try {
    const url = server?.url ?? "";
    const substitute = (value: string) => value.split("${serve}").join(url);
    const body = step.script
      ? await Bun.file(resolveAgainstRecipe(recipe.path, step.script)).text()
      : substitute(step.run!);
    const env = Object.fromEntries(
      Object.entries(step.env).map(([key, value]) => [key, substitute(value)])
    );

    await runInGuest({
      vmId,
      body,
      env,
      timeoutMs: step.timeoutMs,
      label: `step '${step.name}'`,
    });
  } finally {
    server?.stop();
  }
}
