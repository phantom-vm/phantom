import { sendRequest } from "../lib/api";
import { waitForVMRunning } from "../lib/wait";

// MARK: - image build orchestrator
//
// Two ways in, one way out. From scratch:
//   ipsw → vm.create → boot-script (Setup Assistant) → provision (vsock)
//        → gitlab-runner → [install Xcode] → vm.stop → image.save
//
// Or on top of an image built that way — the fast path for layering a toolchain
// onto an existing base, since macOS is already installed and provisioned:
//   vm.create --fromImage → gitlab-runner → [install Xcode] → vm.stop → image.save
//
// The gitlab-runner step runs on both paths, so a published image can be
// refreshed with nothing but that step: build it from itself with --replace and
// no --xcode.

interface BuildOptions {
  imageName: string;
  fromIpsw?: string;
  fromImage?: string;
  bootScript: string;
  provision: string;
  agentDir?: string;
  xcode?: string;
  xcodeScript: string;
  gitlabRunner: boolean;
  gitlabRunnerScript: string;
  gitlabRunnerVersion?: string;
  replace: boolean;
  keepVm: boolean;
}

function parseArgs(args: string[]): BuildOptions | null {
  const opts: BuildOptions = {
    imageName: "",
    bootScript: "provision/setup-tahoe.txt",
    provision: "provision/provision.sh",
    xcodeScript: "provision/install-xcode.sh",
    gitlabRunner: true,
    gitlabRunnerScript: "provision/install-gitlab-runner.sh",
    replace: false,
    keepVm: false,
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--ipsw") opts.fromIpsw = args[++i];
    else if (a === "--image") opts.fromImage = args[++i];
    else if (a === "--boot-script") opts.bootScript = args[++i]!;
    else if (a === "--provision") opts.provision = args[++i]!;
    else if (a === "--agent-dir") opts.agentDir = args[++i];
    else if (a === "--xcode") opts.xcode = args[++i];
    else if (a === "--xcode-script") opts.xcodeScript = args[++i]!;
    else if (a === "--no-gitlab-runner") opts.gitlabRunner = false;
    else if (a === "--gitlab-runner-script") opts.gitlabRunnerScript = args[++i]!;
    else if (a === "--gitlab-runner-version") opts.gitlabRunnerVersion = args[++i];
    else if (a === "--replace") opts.replace = true;
    else if (a === "--keep-vm") opts.keepVm = true;
    else if (!a!.startsWith("--") && !opts.imageName) opts.imageName = a!;
  }

  return opts.imageName ? opts : null;
}

const isURL = (s: string) => /^https?:\/\//.test(s);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function call(method: string, params?: Record<string, any>, timeoutMs = 30_000) {
  const res = await sendRequest({ method, params }, { timeoutMs });
  if (res.error) throw new Error(`${method}: ${res.error.message}`);
  return res.result;
}

async function readScriptLines(path: string): Promise<string[]> {
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`file not found: ${path}`);
  return (await file.text())
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

export async function imageBuild(...args: string[]) {
  const opts = parseArgs(args);
  if (!opts) {
    console.error("Usage: phantom image build <image-name> [options]");
    console.error("  --ipsw <id>            IPSW to install from (default: the only downloaded one)");
    console.error("  --image <name>         Layer onto an existing image instead of installing macOS");
    console.error("                         (skips Setup Assistant and provisioning)");
    console.error("  --boot-script <path>   Setup Assistant script (default: provision/setup-tahoe.txt)");
    console.error("  --provision <path>     Provision script (default: provision/provision.sh)");
    console.error("  --agent-dir <path>     phantom-agent dir to stage into the shared folder first");
    console.error("  --xcode <url|path>     Install Xcode from this .xip (URL fetched inside the guest,");
    console.error("                         local path staged through the shared folder)");
    console.error("  --xcode-script <path>  Xcode installer script (default: provision/install-xcode.sh)");
    console.error("  --no-gitlab-runner     Skip baking gitlab-runner into the image");
    console.error("  --gitlab-runner-version <v>  Runner version to bake in (default: the script's pin)");
    console.error("  --gitlab-runner-script <path>  (default: provision/install-gitlab-runner.sh)");
    console.error("  --replace              Overwrite an existing image of the same name");
    console.error("  --keep-vm              Keep the intermediate VM after saving");
    process.exit(1);
  }

  try {
    await run(opts);
  } catch (err) {
    console.error(`\n✗ Build failed: ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }
}

async function run(opts: BuildOptions) {
  if (opts.fromImage && opts.fromIpsw) {
    throw new Error("--image and --ipsw are mutually exclusive");
  }

  // Getting to a booted, agent-answering VM takes five steps from an IPSW and
  // one from an image; everything after that is shared.
  const total =
    (opts.fromImage ? 1 : 5) + (opts.gitlabRunner ? 1 : 0) + (opts.xcode ? 1 : 0) + 3;
  let n = 0;
  const step = (msg: string) => console.log(`\n[${++n}/${total}] ${msg}`);

  // Read scripts up front so a typo fails before the 20-minute install.
  const bootCommands = opts.fromImage ? [] : await readScriptLines(opts.bootScript);
  let provisionBody = "";
  if (!opts.fromImage) {
    provisionBody = await Bun.file(opts.provision).text();
    if (!provisionBody.trim()) throw new Error(`empty provision script: ${opts.provision}`);
  }

  let runnerBody = "";
  if (opts.gitlabRunner) {
    runnerBody = await Bun.file(opts.gitlabRunnerScript).text();
    if (!runnerBody.trim()) throw new Error(`empty gitlab-runner script: ${opts.gitlabRunnerScript}`);
  }

  // Same for the Xcode installer and, when it is a local .xip, the archive
  // itself — no point installing macOS for an hour to then miss the file.
  let xcodeBody = "";
  if (opts.xcode) {
    xcodeBody = await Bun.file(opts.xcodeScript).text();
    if (!xcodeBody.trim()) throw new Error(`empty Xcode script: ${opts.xcodeScript}`);
    if (!isURL(opts.xcode) && !(await Bun.file(opts.xcode).exists())) {
      throw new Error(`.xip not found: ${opts.xcode}`);
    }
  }

  let vmId: string;

  if (opts.fromImage) {
    // The base image already went through Setup Assistant, the agent install
    // and provisioning, so one step gets us a booted VM. vm.create answers with
    // the vmId right away and decompresses in the background — the restore of a
    // 90GB disk takes minutes, and holding a socket open across it only creates
    // ways to lose the vmId. The guest is still booting when the VM reports
    // running, which the waitForAgent on the next exec absorbs.
    step(`Creating VM from image '${opts.fromImage}'`);
    const createRes = await call("vm.create", { fromImage: opts.fromImage });
    vmId = createRes.vmId;
    await waitForVMRunning(vmId, { onState: (state) => console.log(`    state: ${state}`) });
    console.log(`    VM ${vmId} running`);
  } else {
    // 1. Resolve IPSW
    step("Resolving IPSW");
    const ipswId = await resolveIpsw(opts.fromIpsw);
    console.log(`    using IPSW ${ipswId}`);

    // 2. Stage the agent into the shared folder (optional)
    if (opts.agentDir) {
      step(`Staging phantom-agent from ${opts.agentDir}`);
      await stageAgent(opts.agentDir);
    } else {
      step("Skipping agent staging (assuming shared folder is already staged)");
    }

    // 3. Create the VM and wait out the macOS install
    step("Installing macOS from IPSW (this takes a while)");
    const createRes = await call("vm.create", { ipswId }, 60_000);
    vmId = createRes.vmId;
    console.log(`    VM ${vmId} created; waiting for install...`);
    // 15s between polls: the install's progress percentage moves constantly and
    // every distinct value is a line of build output.
    await waitForVMRunning(vmId, {
      pollMs: 15_000,
      onState: (state) => console.log(`    state: ${state}`),
    });
    console.log(`    install complete, VM running`);

    // 4. Drive Setup Assistant + install the agent over VNC
    step(`Running boot script (${bootCommands.length} commands)`);
    await call("vm.bootScript", { vmId, commands: bootCommands }, 60_000);
    await waitForBootScript(vmId);
    console.log(`    boot script complete`);

    // 5. Provision over vsock (agent is up now)
    step("Provisioning over vsock");
    // 30 min: provisioning includes the headless CLT download + install
    const provRes = await call(
      "vm.exec",
      { vmId, command: provisionBody, waitForAgent: true },
      1_800_000
    );
    if (provRes.exitCode !== 0) {
      throw new Error(`provision script exited ${provRes.exitCode}: ${provRes.stderr ?? ""}`);
    }
    console.log(`    provisioned`);
  }

  // Bake in gitlab-runner (before Xcode: a 60MB download that fails fast beats
  // finding out after three hours of Xcode install)
  if (opts.gitlabRunner) {
    step("Installing gitlab-runner");
    await installGitLabRunner(vmId, runnerBody, opts.gitlabRunnerVersion);
  }

  // Install Xcode (optional)
  if (opts.xcode) {
    step(`Installing Xcode from ${opts.xcode} (+ every simulator runtime)`);
    await installXcode(vmId, opts.xcode, xcodeBody);
  }

  // Flush the guest disk cache, then stop.
  // vm.stop is a force stop (VZVirtualMachine.stop() = "like unplugging the
  // machine"), so anything still in the guest's buffer cache — including the
  // agent install and provisioning — would be lost from the saved image.
  // sync pushes those writes to the virtual disk first.
  step("Flushing disk and stopping VM");
  await call("vm.exec", { vmId, command: "sync; sync; sync", waitForAgent: true }, 60_000);
  await sleep(3_000);
  await call("vm.stop", { vmId }, 60_000);

  // Save the image
  step(`Saving image '${opts.imageName}'${opts.replace ? " (replacing)" : ""}`);
  await call("image.save", { vmId, name: opts.imageName, replace: opts.replace }, 60_000);
  await waitForSave(opts.imageName);
  console.log(`    image saved`);

  // Clean up the intermediate VM
  if (opts.keepVm) {
    step(`Keeping intermediate VM ${vmId} (--keep-vm)`);
  } else {
    step(`Deleting intermediate VM ${vmId}`);
    await call("vm.delete", { vmId }, 60_000);
  }

  console.log(`\n✓ Image '${opts.imageName}' built successfully`);
}

// MARK: - gitlab-runner

// Puts `gitlab-runner` on PATH in the guest, so a job declaring artifacts: or
// cache: gets its upload stages run instead of silently skipped — the custom
// executor runs those inside the job environment too.
async function installGitLabRunner(vmId: string, scriptBody: string, version?: string) {
  // Same trick as the Xcode installer: the version is prepended as an
  // assignment rather than passed as an argument, which vm.exec would append
  // after the script's last line.
  const command = version
    ? `RUNNER_VERSION='${version.replace(/'/g, "'\\''")}'\n${scriptBody}`
    : scriptBody;
  const res = await call("vm.exec", { vmId, command, waitForAgent: true }, 15 * 60_000);
  const log = (res.stdout as string) ?? "";
  for (const line of log.split("\n").filter((l) => l.trim())) console.log(`    ${line}`);
  if (res.exitCode !== 0) {
    throw new Error(`gitlab-runner install exited ${res.exitCode}: ${res.stderr ?? ""}`);
  }
  if (!log.includes("GITLAB_RUNNER_INSTALL_DONE")) {
    throw new Error("gitlab-runner install did not report completion");
  }
}

// MARK: - Xcode

// Runs the installer script inside the guest. The script takes its source from
// XCODE_SRC, prepended here rather than passed as an argument because vm.exec's
// args are appended to the command string — which for a multi-line script body
// would land them on the last line.
async function installXcode(vmId: string, source: string, scriptBody: string) {
  let guestSrc = source;
  if (!isURL(source)) {
    guestSrc = await stageXip(source);
    console.log(`    staged into the shared folder as ${guestSrc}`);
  }

  const command = `XCODE_SRC='${guestSrc.replace(/'/g, "'\\''")}'\n${scriptBody}`;
  // 3h: a ~10GB download plus xip expansion, first launch and every runtime.
  const res = await call("vm.exec", { vmId, command, waitForAgent: true }, 3 * 3600_000);
  const log = (res.stdout as string) ?? "";
  for (const line of log.split("\n").filter((l) => l.trim())) console.log(`    ${line}`);
  if (res.exitCode !== 0) {
    throw new Error(`Xcode install exited ${res.exitCode}: ${res.stderr ?? ""}`);
  }
  if (!log.includes("XCODE_INSTALL_DONE")) {
    throw new Error("Xcode install did not report completion");
  }
}

// Copies a local .xip into the host's shared folder, which the guest sees at
// /Volumes/phantom-shared. Returns the guest-side path.
async function stageXip(path: string): Promise<string> {
  const name = path.split("/").pop()!;
  const shared = `${process.env.HOME}/Library/Application Support/phantom/shared`;
  const proc = Bun.spawn(["cp", path, `${shared}/${name}`], {
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await proc.exited) !== 0) throw new Error(`failed to stage ${path} into ${shared}`);
  return `/Volumes/phantom-shared/${name}`;
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

async function stageAgent(agentDir: string) {
  const proc = Bun.spawn(["./init-host-shared-folder.sh"], {
    cwd: agentDir,
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  if (code !== 0) throw new Error(`init-host-shared-folder.sh exited ${code}`);
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

// Waits out image.save, which is fire-and-forget on the daemon side.
//
// This tracks image.status rather than watching for the name to turn up in
// image.list: with --replace the name is there the whole time (that is the
// point — the old image stays usable until the new one is complete), so a
// list-based wait returns immediately and the VM gets deleted out from under
// the save that is still reading its disk.
//
// A save is only over once the state leaves `saving`, so wait for that state to
// appear first — a stale `completed` from an earlier operation would otherwise
// end the wait before the save had begun. Chunking a real VM disk takes minutes,
// so the window cannot be missed at this poll interval.
async function waitForSave(name: string, maxMs = 60 * 60_000) {
  const deadline = Date.now() + maxMs;
  let started = false;
  let lastMsg = "";
  while (Date.now() < deadline) {
    const { state, message } = (await call("image.status")) as {
      state: string;
      message?: string;
    };
    if (state === "saving") {
      started = true;
      if (message && message !== lastMsg) {
        console.log(`    ${message}`);
        lastMsg = message;
      }
    } else if (started) {
      if (state === "completed") return;
      throw new Error(`image save failed (${state}): ${message ?? ""}`);
    }
    await sleep(3_000);
  }
  throw new Error(`image save of '${name}' timed out`);
}
