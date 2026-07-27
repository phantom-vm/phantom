import { sendRequest, type VM } from "../lib/api";
import { waitForVMRunning } from "../lib/wait";
import { usageError, type Command } from "../command";

export async function vmDeploy(...args: string[]) {
  // Parse flags
  let fromVm: string | undefined;
  let fromIpsw: string | undefined;
  let fromImage: string | undefined;
  let name: string | undefined;
  let cpuCount: number | undefined;
  let memoryGB: number | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--template-vm" && i + 1 < args.length) {
      fromVm = args[i + 1];
      i++;
    } else if (args[i] === "--ipsw" && i + 1 < args.length) {
      fromIpsw = args[i + 1];
      i++;
    } else if (args[i] === "--image" && i + 1 < args.length) {
      fromImage = args[i + 1];
      i++;
    } else if (args[i] === "--name" && i + 1 < args.length) {
      name = args[i + 1];
      i++;
    } else if (args[i] === "--cpu" && i + 1 < args.length) {
      cpuCount = Number(args[i + 1]);
      i++;
    } else if (args[i] === "--memory" && i + 1 < args.length) {
      memoryGB = Number(args[i + 1]);
      i++;
    }
  }

  // The daemon range-checks these against the host; catching the unparseable
  // ones here keeps a typo from arriving as NaN.
  for (const [flag, value] of [["--cpu", cpuCount], ["--memory", memoryGB]] as const) {
    if (value !== undefined && (!Number.isFinite(value) || value <= 0)) {
      console.error(`Error: ${flag} must be a positive number`);
      process.exit(1);
    }
  }

  // Validate flags
  const sources = [fromVm, fromIpsw, fromImage].filter(Boolean);
  if (sources.length === 0) {
    console.error("Error: Must specify one of --image, --ipsw, or --template-vm");
    console.error("");
    usage("deploy");
    process.exit(1);
  }

  if (sources.length > 1) {
    console.error(
      "Error: Cannot specify multiple sources (--ipsw, --template-vm, --image)"
    );
    process.exit(1);
  }

  // Regular create
  const params: {
    ipswId?: string;
    sourceVmId?: string;
    fromImage?: string;
    name?: string;
    cpuCount?: number;
    memoryGB?: number;
  } = fromIpsw
    ? { ipswId: fromIpsw }
    : fromImage
      ? { fromImage }
      : { sourceVmId: fromVm };

  if (name !== undefined) params.name = name;
  if (cpuCount !== undefined) params.cpuCount = cpuCount;
  if (memoryGB !== undefined) params.memoryGB = memoryGB;

  const sourceType = fromIpsw ? "IPSW" : fromImage ? "image" : "VM";
  const sourceId = fromIpsw || fromImage || fromVm;

  console.log(`Creating VM from ${sourceType} ${sourceId}...`);

  // Cloning is the only synchronous one left, and it is an APFS copy-on-write
  // clone — fast enough that a 60s budget is generous.
  const response = await sendRequest(
    { method: "vm.create", params },
    { timeoutMs: 60_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  const vmId = response.result?.vmId as string | undefined;
  if (vmId) {
    console.log(`VM ID: ${vmId}`);
  }

  // Restoring an image runs in the background on the daemon — follow it here so
  // the command still returns a booted VM, but from polling rather than from
  // holding a connection open for the whole decompression.
  if (fromImage && vmId) {
    try {
      await waitForVMRunning(vmId, {
        onState: (state) => console.log(`  ${state}`),
      });
    } catch (err) {
      console.error(`Error: ${err instanceof Error ? err.message : err}`);
      process.exit(1);
    }
    console.log(`VM ${vmId} running`);
    return;
  }

  // An IPSW install takes ~20 minutes; leave the waiting to the user.
  if (response.result?.status === "started") {
    console.log(
      "\nNote: installation runs in the background. Use 'phantom vm list' to check status."
    );
  }
}

export async function vmList() {
  const response = await sendRequest({ method: "vm.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const vms = response.result?.vms as VM[] || [];

  if (vms.length === 0) {
    console.log("No VMs.");
    return;
  }

  console.log("VM ID                STATE");
  for (const vm of vms) {
    console.log(`${vm.id.padEnd(20)} ${vm.state}`);
  }
}

export async function vmStart(vmId: string) {
  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("start");
    process.exit(1);
  }

  console.log(`Starting VM ${vmId}...`);

  const response = await sendRequest(
    { method: "vm.start", params: { vmId } },
    { timeoutMs: 120_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} running`);
}

export async function vmStop(vmId: string) {
  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("stop");
    process.exit(1);
  }

  console.log(`Stopping VM ${vmId}...`);

  const response = await sendRequest({
    method: "vm.stop",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} stopped`);
}

export async function vmExec(...args: string[]) {
  // Parse: <vm-id> [--user <name>] -- <command> [args...]
  const dashDashIndex = args.indexOf("--");
  if (dashDashIndex === -1 || dashDashIndex === 0) {
    console.error("Error: a -- separator followed by the command is required");
    console.error("");
    usage("exec");
    process.exit(1);
  }

  const vmId = args[0]!; // guaranteed present since dashDashIndex >= 1
  let user: string | undefined;
  for (let i = 1; i < dashDashIndex; i++) {
    if (args[i] === "--user" && i + 1 < dashDashIndex) {
      user = args[i + 1];
      i++;
    }
  }
  const command = args.slice(dashDashIndex + 1).join(" ");

  if (!command) {
    console.error("Error: command required after --");
    process.exit(1);
  }

  const params: { vmId: string; command: string; user?: string } = { vmId, command };
  if (user) params.user = user;

  const response = await sendRequest(
    { method: "vm.exec", params },
    { timeoutMs: 300_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const { stdout, stderr, exitCode } = response.result;
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);
  process.exit(exitCode);
}

export async function vmDisplay(vmId: string) {
  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("display");
    process.exit(1);
  }

  const response = await sendRequest({
    method: "vm.display",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Display opened for VM ${vmId}`);
}

export async function vmVnc(...args: string[]) {
  const stop = args.includes("--stop");
  const vmId = args.find((a) => !a.startsWith("--"));

  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("vnc");
    process.exit(1);
  }

  if (stop) {
    const response = await sendRequest({
      method: "vm.vnc.stop",
      params: { vmId },
    });

    if (response.error) {
      console.error(`Error: ${response.error.message}`);
      process.exit(1);
    }

    console.log(`VNC server stopped for VM ${vmId}`);
    return;
  }

  const response = await sendRequest({
    method: "vm.vnc.start",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.url);
}

export async function vmBootScript(...args: string[]) {
  const fileIndex = args.indexOf("--file");
  const filePath = fileIndex !== -1 ? args[fileIndex + 1] : undefined;
  const vmId = args.find((a, i) => !a.startsWith("--") && i !== fileIndex + 1);

  if (!vmId || !filePath) {
    console.error("");
    usage("boot-script");
    console.error(
      "Script file: one boot command per line, blank lines and # comments ignored"
    );
    process.exit(1);
  }

  const file = Bun.file(filePath);
  if (!(await file.exists())) {
    console.error(`Error: file not found: ${filePath}`);
    process.exit(1);
  }

  const commands = (await file.text())
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"));

  if (commands.length === 0) {
    console.error("Error: script file contains no commands");
    process.exit(1);
  }

  const response = await sendRequest(
    { method: "vm.bootScript", params: { vmId, commands } },
    { timeoutMs: 60_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Boot script started (${commands.length} commands)`);

  // Poll status until the script finishes
  let lastMessage = "";
  while (true) {
    await new Promise((resolve) => setTimeout(resolve, 2000));

    const status = await sendRequest({
      method: "vm.bootScript.status",
      params: { vmId },
    });

    if (status.error) {
      console.error(`Error: ${status.error.message}`);
      process.exit(1);
    }

    const { state, message } = status.result as {
      state: string;
      message?: string;
    };

    if (state === "running" && message && message !== lastMessage) {
      console.log(message);
      lastMessage = message;
    } else if (state === "completed") {
      console.log("Boot script completed");
      return;
    } else if (state === "error") {
      console.error(`Boot script failed: ${message}`);
      process.exit(1);
    } else if (state === "idle") {
      console.error("Boot script state lost (daemon restarted?)");
      process.exit(1);
    }
  }
}

export async function vmScreenshot(...args: string[]) {
  const outIndex = args.indexOf("--out");
  const outPath = outIndex !== -1 ? args[outIndex + 1] : undefined;
  const vmId = args.find((a, i) => !a.startsWith("--") && i !== outIndex + 1);

  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("screenshot");
    process.exit(1);
  }

  const params: { vmId: string; path?: string } = { vmId };
  if (outPath) params.path = outPath;

  const response = await sendRequest(
    { method: "vm.screenshot", params },
    { timeoutMs: 30_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.path);
}

export async function vmDelete(vmId: string) {
  if (!vmId) {
    console.error("Error: a VM id is required");
    console.error("");
    usage("delete");
    process.exit(1);
  }

  console.log(`Deleting VM ${vmId}...`);

  const response = await sendRequest({
    method: "vm.delete",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} deleted`);
}

export const commands: Record<string, Command> = {
  deploy: {
    usage: "--image <name> [options]",
    description: "Boot a VM from an image, an IPSW or another VM",
    details: [
      "--image <name>      Boot from a local image",
      "--ipsw <id>         Install macOS from a downloaded IPSW instead",
      "--template-vm <id>  Clone an existing VM instead",
      "--name <id>         Name the VM (default: a generated vm-xxxxxxxx)",
      "--cpu <n>           CPU count (default: 4)",
      "--memory <gb>       Memory in GB (default: 16)",
    ],
    multiArgHandler: vmDeploy,
  },
  list: { usage: "", description: "List VMs and their state", handler: vmList as Command["handler"] },
  start: { usage: "<id>", description: "Start a VM", handler: vmStart as Command["handler"] },
  stop: { usage: "<id>", description: "Stop a VM", handler: vmStop as Command["handler"] },
  exec: {
    usage: "<id> [--user <name>] -- <cmd> [args...]",
    description: "Run a command inside a VM over vsock",
    details: [
      "--user <name>  Run as this user through a login shell, which is what a CI",
      "               job gets. Without it the command runs as root without one,",
      "               on a PATH that excludes /usr/local/bin — so a binary",
      "               installed there reads as missing.",
    ],
    multiArgHandler: vmExec,
  },
  display: { usage: "<id>", description: "Open the VM's display window", handler: vmDisplay as Command["handler"] },
  vnc: {
    usage: "<id> [--stop]",
    description: "Start/stop host-side VNC (vnc://...)",
    details: ["--stop  Stop the VNC server instead of starting it"],
    multiArgHandler: vmVnc,
  },
  screenshot: {
    usage: "<id> [--out <path>]",
    description: "Capture the VM's framebuffer",
    details: ["--out <path>  Write the PNG here (default: a temp file, whose path is printed)"],
    multiArgHandler: vmScreenshot,
  },
  delete: { usage: "<id>", description: "Delete a VM", handler: vmDelete as Command["handler"] },
};

/// A handler's usage-error path — same text as `phantom help vm <name>`.
const usage = (name: string) => usageError("vm", name, commands[name] ?? adminCommands[name]!);

// Image authoring: main.ts registers these only under PHANTOM_ADMIN_MODE.
export const adminCommands: Record<string, Command> = {
  "boot-script": {
    usage: "<id> --file <script>",
    description: "Drive Setup Assistant over VNC (used by image build)",
    multiArgHandler: vmBootScript,
  },
};
