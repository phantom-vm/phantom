import { call, flushAndStop, runInGuest, sleep, waitForSave } from "../lib/guest";
import { waitForVMRunning } from "../lib/wait";
import { usageError, type Command } from "../command";

// MARK: - image build-base
//
// IPSW → installed, provisioned, agent-equipped base image:
//
//   ipsw → vm.create → boot-script (Setup Assistant + agent bootstrap via
//        curl | sudo sh of the published phantom-agent-install.sh)
//        → provision (vsock) → vm.stop → image.save
//
// This is the job that happens once per macOS release, and it is the one build
// that is *not* described by a recipe. Its middle is VNC keystrokes against
// Setup Assistant — a stage with no guest agent to run anything in, and one
// whose script has to be rewritten whenever Apple rewords a pane. A recipe
// describes steps run over vsock in a guest that is already up; this has none
// of those until it is nearly done.
//
// What goes *on top* — toolchains, runners, anything a CI job needs — is
// `image build -f <recipe>` (build.ts). A base image stays macOS, the agent and
// provisioning, nothing else.

interface BaseOptions {
  imageName: string;
  fromIpsw?: string;
  bootScript: string;
  provision: string;
  agentUrl?: string;
  replace: boolean;
  keepVm: boolean;
}

function parseArgs(args: string[]): BaseOptions | null {
  const opts: BaseOptions = {
    imageName: "",
    bootScript: "provision/setup-tahoe.txt",
    provision: "provision/provision.sh",
    replace: false,
    keepVm: false,
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--ipsw") opts.fromIpsw = args[++i];
    else if (a === "--boot-script") opts.bootScript = args[++i]!;
    else if (a === "--provision") opts.provision = args[++i]!;
    else if (a === "--agent-url") opts.agentUrl = args[++i];
    else if (a === "--replace") opts.replace = true;
    else if (a === "--keep-vm") opts.keepVm = true;
    else if (!a!.startsWith("--") && !opts.imageName) opts.imageName = a!;
  }

  return opts.imageName ? opts : null;
}

// The installer URL setup-tahoe.txt fetches; --agent-url rewrites it in place.
const RELEASE_AGENT_INSTALL_URL =
  "https://github.com/phantom-vm/phantom/releases/latest/download/phantom-agent-install.sh";

export const buildBaseCommand: Command = {
  usage: "<name> [options]",
  description: "IPSW → agent install → provision → save, unattended",
  details: [
    "--ipsw <id>            IPSW to install from (default: the only downloaded one)",
    "--boot-script <path>   Setup Assistant script (default: provision/setup-tahoe.txt)",
    "--provision <path>     Provision script (default: provision/provision.sh)",
    "--agent-url <url>      phantom-agent-install.sh for the boot script to fetch, instead of",
    "                       the latest GitHub release asset (for agent development)",
    "--replace              Overwrite an existing image of the same name",
    "--keep-vm              Keep the intermediate VM after saving",
  ],
  multiArgHandler: imageBuildBase,
};

export async function imageBuildBase(...args: string[]) {
  const opts = parseArgs(args);
  if (!opts) {
    usageError("image", "build-base", buildBaseCommand);
    process.exit(1);
  }

  try {
    await run(opts);
  } catch (err) {
    console.error(`\n✗ Build failed: ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }
}

async function run(opts: BaseOptions) {
  const total = 7;
  let n = 0;
  const step = (msg: string) => console.log(`\n[${++n}/${total}] ${msg}`);

  // Read the scripts up front so a typo fails before the 20-minute install.
  let bootCommands = await readScriptLines(opts.bootScript);

  // Agent development override: retarget the boot script's installer fetch
  // from the published release asset to a dev-served phantom-agent-install.sh.
  if (opts.agentUrl) {
    const before = bootCommands;
    bootCommands = bootCommands.map((l) =>
      l.split(RELEASE_AGENT_INSTALL_URL).join(opts.agentUrl!)
    );
    if (bootCommands.every((l, i) => l === before[i])) {
      throw new Error(
        `--agent-url given, but ${opts.bootScript} does not fetch ${RELEASE_AGENT_INSTALL_URL}`
      );
    }
  }

  const provisionBody = await Bun.file(opts.provision).text();
  if (!provisionBody.trim()) throw new Error(`empty provision script: ${opts.provision}`);

  // 1. Resolve IPSW
  step("Resolving IPSW");
  const ipswId = await resolveIpsw(opts.fromIpsw);
  console.log(`    using IPSW ${ipswId}`);

  // 2. Create the VM and wait out the macOS install
  step("Installing macOS from IPSW (this takes a while)");
  const createRes = await call("vm.create", { ipswId }, 60_000);
  const vmId: string = createRes.vmId;
  console.log(`    VM ${vmId} created; waiting for install...`);
  // 15s between polls: the install's progress percentage moves constantly and
  // every distinct value is a line of build output.
  await waitForVMRunning(vmId, {
    pollMs: 15_000,
    onState: (state) => console.log(`    state: ${state}`),
  });
  console.log(`    install complete, VM running`);

  // 3. Drive Setup Assistant + install the agent over VNC
  step(`Running boot script (${bootCommands.length} commands)`);
  await call("vm.bootScript", { vmId, commands: bootCommands }, 60_000);
  await waitForBootScript(vmId);
  console.log(`    boot script complete`);

  // 4. Provision over vsock (agent is up now)
  step("Provisioning over vsock");
  // 30 min: provisioning includes the headless CLT download + install
  await runInGuest({
    vmId,
    body: provisionBody,
    timeoutMs: 1_800_000,
    // The one step that is root by name: it writes the sudoers file admin's
    // passwordless sudo comes from, so it cannot be the thing that uses it.
    user: "root",
    label: "provision script",
  });
  console.log(`    provisioned`);

  // 5. Flush the guest disk cache, then stop
  step("Flushing disk and stopping VM");
  await flushAndStop(vmId);

  // 6. Save the image
  step(`Saving image '${opts.imageName}'${opts.replace ? " (replacing)" : ""}`);
  await call("image.save", { vmId, name: opts.imageName, replace: opts.replace }, 60_000);
  await waitForSave(opts.imageName);
  console.log(`    image saved`);

  // 7. Clean up the intermediate VM
  if (opts.keepVm) {
    step(`Keeping intermediate VM ${vmId} (--keep-vm)`);
  } else {
    step(`Deleting intermediate VM ${vmId}`);
    await call("vm.delete", { vmId }, 60_000);
  }

  console.log(`\n✓ Base image '${opts.imageName}' built successfully`);
  console.log(`  Layer a toolchain onto it with 'phantom image build -f <recipe.yaml>'.`);
}

async function readScriptLines(path: string): Promise<string[]> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`file not found: ${path}`);
  return (await file.text())
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

async function resolveIpsw(fromIpsw?: string): Promise<string> {
  const res = await call("ipsw.list");
  const ipsws: { id: string }[] = res.ipsws ?? [];
  if (fromIpsw) {
    if (!ipsws.some((i) => i.id === fromIpsw)) {
      throw new Error(`IPSW '${fromIpsw}' not downloaded. Run 'phantom ipsw pull' first.`);
    }
    return fromIpsw;
  }
  if (ipsws.length === 0) throw new Error("No IPSW downloaded. Run 'phantom ipsw pull' first.");
  if (ipsws.length > 1) {
    throw new Error(
      `Multiple IPSWs found (${ipsws.map((i) => i.id).join(", ")}). Specify one with --ipsw.`
    );
  }
  return ipsws[0]!.id;
}

async function waitForBootScript(vmId: string, maxMs = 20 * 60_000) {
  const deadline = Date.now() + maxMs;
  let lastMsg = "";
  while (Date.now() < deadline) {
    const res = await call("vm.bootScript.status", { vmId });
    const { state, message } = res as { state: string; message?: string };
    if (message && message !== lastMsg) {
      console.log(`    ${message}`);
      lastMsg = message;
    }
    if (state === "completed") return;
    if (state === "error") throw new Error(`boot script failed: ${message}`);
    if (state === "idle") throw new Error("boot script state lost (daemon restarted?)");
    await sleep(3_000);
  }
  throw new Error("boot script timed out");
}
