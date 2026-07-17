import { sendRequest, type VM } from "../lib/api";

// MARK: - image build orchestrator
//
// One command from IPSW to a ready-to-use, agent-installed base image:
//   ipsw → vm.create → boot-script (Setup Assistant) → provision (vsock)
//        → vm.stop → image.save

interface BuildOptions {
  imageName: string;
  fromIpsw?: string;
  bootScript: string;
  provision: string;
  agentDir?: string;
  keepVm: boolean;
}

function parseArgs(args: string[]): BuildOptions | null {
  const opts: BuildOptions = {
    imageName: "",
    bootScript: "provision/setup-tahoe.txt",
    provision: "provision/provision.sh",
    keepVm: false,
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--from-ipsw") opts.fromIpsw = args[++i];
    else if (a === "--boot-script") opts.bootScript = args[++i]!;
    else if (a === "--provision") opts.provision = args[++i]!;
    else if (a === "--agent-dir") opts.agentDir = args[++i];
    else if (a === "--keep-vm") opts.keepVm = true;
    else if (!a!.startsWith("--") && !opts.imageName) opts.imageName = a!;
  }

  return opts.imageName ? opts : null;
}

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
    console.error("  --from-ipsw <id>       IPSW to install from (default: the only downloaded one)");
    console.error("  --boot-script <path>   Setup Assistant script (default: provision/setup-tahoe.txt)");
    console.error("  --provision <path>     Provision script (default: provision/provision.sh)");
    console.error("  --agent-dir <path>     phantom-agent dir to stage into the shared folder first");
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
  const step = (n: number, msg: string) => console.log(`\n[${n}/8] ${msg}`);

  // Read scripts up front so a typo fails before the 20-minute install.
  const bootCommands = await readScriptLines(opts.bootScript);
  const provisionBody = await Bun.file(opts.provision).text();
  if (!provisionBody.trim()) throw new Error(`empty provision script: ${opts.provision}`);

  // 1. Resolve IPSW
  step(1, "Resolving IPSW");
  const ipswId = await resolveIpsw(opts.fromIpsw);
  console.log(`    using IPSW ${ipswId}`);

  // 2. Stage the agent into the shared folder (optional)
  if (opts.agentDir) {
    step(2, `Staging phantom-agent from ${opts.agentDir}`);
    await stageAgent(opts.agentDir);
  } else {
    step(2, "Skipping agent staging (assuming shared folder is already staged)");
  }

  // 3. Create the VM and wait out the macOS install
  step(3, "Installing macOS from IPSW (this takes a while)");
  const createRes = await call("vm.create", { ipswId }, 60_000);
  const vmId: string = createRes.vmId;
  console.log(`    VM ${vmId} created; waiting for install...`);
  await waitForInstall(vmId);
  console.log(`    install complete, VM running`);

  // 4. Drive Setup Assistant + install the agent over VNC
  step(4, `Running boot script (${bootCommands.length} commands)`);
  await call("vm.bootScript", { vmId, commands: bootCommands }, 60_000);
  await waitForBootScript(vmId);
  console.log(`    boot script complete`);

  // 5. Provision over vsock (agent is up now)
  step(5, "Provisioning over vsock");
  const provRes = await call(
    "vm.exec",
    { vmId, command: provisionBody, waitForAgent: true },
    600_000
  );
  if (provRes.exitCode !== 0) {
    throw new Error(`provision script exited ${provRes.exitCode}: ${provRes.stderr ?? ""}`);
  }
  console.log(`    provisioned`);

  // 6. Flush the guest disk cache, then stop.
  // vm.stop is a force stop (VZVirtualMachine.stop() = "like unplugging the
  // machine"), so anything still in the guest's buffer cache — including the
  // agent install and provisioning — would be lost from the saved image.
  // sync pushes those writes to the virtual disk first.
  step(6, "Flushing disk and stopping VM");
  await call("vm.exec", { vmId, command: "sync; sync; sync", waitForAgent: true }, 60_000);
  await sleep(3_000);
  await call("vm.stop", { vmId }, 60_000);

  // 7. Save the image
  step(7, `Saving image '${opts.imageName}'`);
  await call("image.save", { vmId, name: opts.imageName }, 60_000);
  await waitForImage(opts.imageName);
  console.log(`    image saved`);

  // 8. Clean up the intermediate VM
  if (opts.keepVm) {
    step(8, `Keeping intermediate VM ${vmId} (--keep-vm)`);
  } else {
    step(8, `Deleting intermediate VM ${vmId}`);
    await call("vm.delete", { vmId }, 60_000);
  }

  console.log(`\n✓ Image '${opts.imageName}' built successfully`);
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
      `Multiple IPSWs found (${ipsws.map((i) => i.id).join(", ")}). Specify one with --from-ipsw.`
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

async function findVM(vmId: string): Promise<VM | undefined> {
  const res = await call("vm.list");
  return (res.vms as VM[]).find((v) => v.id === vmId);
}

async function waitForInstall(vmId: string, maxMs = 45 * 60_000) {
  const deadline = Date.now() + maxMs;
  let lastState = "";
  while (Date.now() < deadline) {
    const vm = await findVM(vmId);
    if (!vm) throw new Error(`VM ${vmId} disappeared during install`);
    if (vm.state !== lastState) {
      console.log(`    state: ${vm.state}`);
      lastState = vm.state;
    }
    if (vm.state === "running") return;
    if (vm.state.startsWith("error")) throw new Error(`install failed: ${vm.state}`);
    await sleep(15_000);
  }
  throw new Error("install timed out");
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

async function waitForImage(name: string, maxMs = 10 * 60_000) {
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    const res = await call("image.list");
    if ((res.images as { name: string }[]).some((i) => i.name === name)) return;
    await sleep(3_000);
  }
  throw new Error("image save timed out");
}
