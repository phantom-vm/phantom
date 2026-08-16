// A recipe: the file that says what a layered image is made of.
//
// Everything an `image build` used to take as flags — which base to layer onto,
// which scripts to run, which Xcode, which runner version — is written down
// here instead, in a file that lives next to the image it describes. That is
// the whole point: what went into an image should be readable a year later
// without reconstructing somebody's shell history.
//
//   schema: 1
//   name: xcode-26-6
//   description: macOS 26 + Xcode 26.6 and every simulator runtime
//   from: tahoe-base
//   steps:
//     - name: gitlab-runner
//       script: provision/install-gitlab-runner.sh
//       env: { RUNNER_VERSION: v18.11.2 }
//       expect: GITLAB_RUNNER_INSTALL_DONE
//     - name: xcode
//       script: provision/install-xcode.sh
//       serve: ~/Downloads/Xcode-26.6.0.xip
//       env: { XCODE_SRC: "${serve}" }
//       timeout: 4h
//
// Building a *base* image from an IPSW is `image build-base`, not a recipe:
// it is one job per macOS release, and its Setup Assistant stage is VNC
// keystrokes rather than a command in a guest that has no agent yet. Recipes
// describe layering, where every step is one thing run over vsock.

import { dirname, isAbsolute, resolve } from "node:path";
import { homedir } from "node:os";

/// One thing done to the guest: a script file or an inline command, run over
/// vsock with `env` prepended as assignments.
export interface RecipeStep {
  name: string;
  /// Path to a script, resolved against the recipe's own directory.
  script?: string;
  /// An inline command, for a step too small to deserve a file.
  run?: string;
  /// Prepended to the command as `KEY='value'` lines — the way the Xcode and
  /// runner scripts have always taken their input, since vm.exec appends its
  /// args after the last line of a multi-line body rather than to the command.
  env: Record<string, string>;
  /// A local file the guest can't otherwise reach, served over the vmnet
  /// bridge for the duration of the step. `${serve}` in `env` or `run`
  /// expands to its URL.
  serve?: string;
  /// How long the step may take. A guest install that hangs must not hang the
  /// build forever, and the honest limits differ by hours between steps.
  timeoutMs: number;
  /// Text the step must print to count as done. A script that exits 0 having
  /// silently skipped its work is the failure this catches — both installers
  /// already end with such a marker.
  expect?: string;
}

export interface Recipe {
  /// Where it was read from, kept for error messages and for the build record.
  path: string;
  schema: number;
  name: string;
  description?: string;
  /// The base image this layers onto.
  from: string;
  steps: RecipeStep[];
  /// The file verbatim. PHANTOM-64 records this inside the image; here it is
  /// also what `--dry-run` can echo without re-reading the file.
  source: string;
}

/// Everything wrong with a recipe is reported this way: the file, and the step
/// when there is one. A recipe is read before a VM exists, so a mistake in it
/// costs a second — as long as the message says where to look.
export class RecipeError extends Error {
  constructor(path: string, message: string, step?: string) {
    super(step ? `${path}: step '${step}': ${message}` : `${path}: ${message}`);
    this.name = "RecipeError";
  }
}

const SCHEMA = 1;
const DEFAULT_TIMEOUT_MS = 30 * 60_000;

/// The daemon's rule for an image name, which is also a directory name under
/// `images/`. Checked here so a recipe that cannot produce an image says so
/// before the build rather than after it.
const NAME_RULE = /^[A-Za-z0-9_-]{1,64}$/;

const RECIPE_KEYS = new Set(["schema", "name", "description", "from", "steps"]);
const STEP_KEYS = new Set(["name", "script", "run", "env", "serve", "timeout", "expect"]);

/// `4h`, `90m`, `30s`, or a bare number of seconds.
function parseDuration(value: unknown, path: string, step: string): number {
  if (typeof value === "number") return value * 1000;
  if (typeof value !== "string" || !/^\d+(\.\d+)?[smh]?$/.test(value.trim())) {
    throw new RecipeError(path, `timeout must look like '30s', '90m' or '4h', got ${JSON.stringify(value)}`, step);
  }
  const text = value.trim();
  const unit = text.at(-1)!;
  const amount = parseFloat(text);
  const scale = unit === "h" ? 3600_000 : unit === "m" ? 60_000 : 1000;
  return Math.round(amount * scale);
}

/// `~` is expanded here rather than left to the shell: a recipe path is read by
/// this process, never passed to one.
export function resolveAgainstRecipe(recipePath: string, path: string): string {
  const expanded = path.startsWith("~/") ? resolve(homedir(), path.slice(2)) : path;
  return isAbsolute(expanded) ? expanded : resolve(dirname(resolve(recipePath)), expanded);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/// Parses and validates. Unknown keys are errors, not noise: a recipe is meant
/// to be the account of an image, and a misspelled key that is quietly ignored
/// makes it a false one.
export function parseRecipe(source: string, path: string): Recipe {
  let raw: unknown;
  try {
    raw = Bun.YAML.parse(source);
  } catch (err) {
    throw new RecipeError(path, `not valid YAML — ${err instanceof Error ? err.message : err}`);
  }

  const doc = asRecord(raw);
  if (!doc) throw new RecipeError(path, "a recipe is a YAML mapping with schema, name, from and steps");

  for (const key of Object.keys(doc)) {
    if (!RECIPE_KEYS.has(key)) {
      throw new RecipeError(path, `unknown key '${key}' (expected ${[...RECIPE_KEYS].join(", ")})`);
    }
  }

  if (doc.schema !== SCHEMA) {
    throw new RecipeError(
      path,
      doc.schema === undefined
        ? `missing 'schema: ${SCHEMA}'`
        : `unsupported schema ${JSON.stringify(doc.schema)} (this phantom understands ${SCHEMA})`
    );
  }

  const name = doc.name;
  if (typeof name !== "string" || !NAME_RULE.test(name)) {
    throw new RecipeError(
      path,
      `name must be letters, digits, '-' and '_', up to 64 — got ${JSON.stringify(name)}`
    );
  }

  const from = doc.from;
  if (typeof from !== "string" || !NAME_RULE.test(from)) {
    throw new RecipeError(
      path,
      `from must name the base image to layer onto — got ${JSON.stringify(from)}`
    );
  }
  if (doc.description !== undefined && typeof doc.description !== "string") {
    throw new RecipeError(path, "description must be a string");
  }

  if (!Array.isArray(doc.steps) || doc.steps.length === 0) {
    throw new RecipeError(path, "steps must be a non-empty list — an image with no steps is its base");
  }

  const seen = new Set<string>();
  const steps = doc.steps.map((entry, i) => parseStep(entry, i, path, seen));

  return {
    path,
    schema: SCHEMA,
    name,
    description: typeof doc.description === "string" ? doc.description : undefined,
    from,
    steps,
    source,
  };
}

function parseStep(entry: unknown, index: number, path: string, seen: Set<string>): RecipeStep {
  const step = asRecord(entry);
  if (!step) throw new RecipeError(path, `step ${index + 1} is not a mapping`);

  const label = typeof step.name === "string" ? step.name : `step ${index + 1}`;

  for (const key of Object.keys(step)) {
    if (!STEP_KEYS.has(key)) {
      throw new RecipeError(path, `unknown key '${key}' (expected ${[...STEP_KEYS].join(", ")})`, label);
    }
  }

  if (typeof step.name !== "string" || !step.name.trim()) {
    throw new RecipeError(path, `step ${index + 1} needs a name — it is how the build reports progress`);
  }
  // Names identify a step in the build output, and will identify it in the
  // build record an image carries; two of the same would make both ambiguous.
  if (seen.has(step.name)) throw new RecipeError(path, `duplicate step name '${step.name}'`);
  seen.add(step.name);

  const hasScript = typeof step.script === "string" && step.script.trim() !== "";
  const hasRun = typeof step.run === "string" && step.run.trim() !== "";
  if (hasScript === hasRun) {
    throw new RecipeError(
      path,
      hasScript ? "give either script or run, not both" : "needs a script (a file) or a run (an inline command)",
      step.name
    );
  }

  const env: Record<string, string> = {};
  if (step.env !== undefined) {
    const given = asRecord(step.env);
    if (!given) throw new RecipeError(path, "env must be a mapping of names to values", step.name);
    for (const [key, value] of Object.entries(given)) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
        throw new RecipeError(path, `'${key}' is not an environment variable name`, step.name);
      }
      if (value === null || typeof value === "object") {
        throw new RecipeError(path, `env.${key} must be a string, number or boolean`, step.name);
      }
      env[key] = String(value);
    }
  }

  if (step.serve !== undefined && (typeof step.serve !== "string" || !step.serve.trim())) {
    throw new RecipeError(path, "serve must be a path to a local file", step.name);
  }
  if (step.expect !== undefined && (typeof step.expect !== "string" || !step.expect.trim())) {
    throw new RecipeError(path, "expect must be the text the step prints when it succeeds", step.name);
  }

  const body = hasScript ? "" : (step.run as string);
  const usesServe = [body, ...Object.values(env)].some((v) => v.includes("${serve}"));
  if (step.serve && !usesServe) {
    throw new RecipeError(
      path,
      "serve is set but nothing uses ${serve} — the guest would never be told the URL",
      step.name
    );
  }
  if (!step.serve && usesServe) {
    throw new RecipeError(path, "${serve} is used but no file is served", step.name);
  }

  return {
    name: step.name,
    script: hasScript ? (step.script as string) : undefined,
    run: hasRun ? (step.run as string) : undefined,
    env,
    serve: typeof step.serve === "string" ? step.serve : undefined,
    timeoutMs: step.timeout === undefined ? DEFAULT_TIMEOUT_MS : parseDuration(step.timeout, path, step.name),
    expect: typeof step.expect === "string" ? step.expect : undefined,
  };
}

/// Reads the recipe and checks that every file it names is there. Both halves
/// run before the build starts: a missing `.xip` must not surface half an hour
/// into a restore.
export async function loadRecipe(path: string): Promise<Recipe> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new RecipeError(path, "no such recipe file");

  const recipe = parseRecipe(await file.text(), path);

  for (const step of recipe.steps) {
    for (const [kind, value] of [["script", step.script], ["serve", step.serve]] as const) {
      if (!value) continue;
      const resolved = resolveAgainstRecipe(path, value);
      if (!(await Bun.file(resolved).exists())) {
        throw new RecipeError(path, `${kind} not found: ${value} (looked in ${resolved})`, step.name);
      }
    }
  }

  return recipe;
}
