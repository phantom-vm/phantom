import { sendRequest, type VM } from "../lib/api";

export async function vmDeploy(...args: string[]) {
  // Parse flags
  let fromVm: string | undefined;
  let fromIpsw: string | undefined;
  let fromImage: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--from-vm" && i + 1 < args.length) {
      fromVm = args[i + 1];
      i++;
    } else if (args[i] === "--from-ipsw" && i + 1 < args.length) {
      fromIpsw = args[i + 1];
      i++;
    } else if (args[i] === "--from-image" && i + 1 < args.length) {
      fromImage = args[i + 1];
      i++;
    }
  }

  // Validate flags
  const sources = [fromVm, fromIpsw, fromImage].filter(Boolean);
  if (sources.length === 0) {
    console.error(
      "Error: Must specify one of --from-vm, --from-ipsw, or --from-image"
    );
    console.error("Usage:");
    console.error("  phantom vm deploy --from-ipsw <ipsw-id>");
    console.error("  phantom vm deploy --from-vm <vm-id>");
    console.error("  phantom vm deploy --from-image <image-name>");
    process.exit(1);
  }

  if (sources.length > 1) {
    console.error(
      "Error: Cannot specify multiple sources (--from-vm, --from-ipsw, --from-image)"
    );
    process.exit(1);
  }

  // Regular create
  const params: { ipswId?: string; sourceVmId?: string; fromImage?: string } =
    fromIpsw
      ? { ipswId: fromIpsw }
      : fromImage
        ? { fromImage }
        : { sourceVmId: fromVm };

  const sourceType = fromIpsw ? "IPSW" : fromImage ? "image" : "VM";
  const sourceId = fromIpsw || fromImage || fromVm;

  console.log(`Creating VM from ${sourceType} ${sourceId}...`);

  const response = await sendRequest(
    { method: "vm.create", params },
    { timeoutMs: 600_000 }
  );

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  if (response.result?.vmId) {
    console.log(`VM ID: ${response.result.vmId}`);
  }
  console.log(
    "\nNote: VM creation happens in the background. Use 'phantom vm list' to check status."
  );
}

export async function vmList() {
  const response = await sendRequest({ method: "vm.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const vms = response.result?.vms as VM[] || [];

  if (vms.length === 0) {
    console.log("No VMs. Run 'phantom vm deploy --from-ipsw <IPSW_ID>' to create one.");
    return;
  }

  console.log("VM ID                STATE");
  for (const vm of vms) {
    console.log(`${vm.id.padEnd(20)} ${vm.state}`);
  }
}

export async function vmStart(vmId: string) {
  if (!vmId) {
    console.error("Error: VM_ID required");
    console.error("Usage: phantom vm start <VM_ID>");
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
    console.error("Error: VM_ID required");
    console.error("Usage: phantom vm stop <VM_ID>");
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
  // Parse: <vm-id> -- <command> [args...]
  const dashDashIndex = args.indexOf("--");
  if (dashDashIndex === -1 || dashDashIndex === 0) {
    console.error("Usage: phantom vm exec <VM_ID> -- <command> [args...]");
    process.exit(1);
  }

  const vmId = args[0];
  const command = args.slice(dashDashIndex + 1).join(" ");

  if (!command) {
    console.error("Error: command required after --");
    process.exit(1);
  }

  const response = await sendRequest(
    {
      method: "vm.exec",
      params: { vmId, command },
    },
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
    console.error("Error: VM_ID required");
    console.error("Usage: phantom vm display <VM_ID>");
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
    console.error("Error: VM_ID required");
    console.error("Usage: phantom vm vnc <VM_ID> [--stop]");
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
    console.error("Usage: phantom vm boot-script <VM_ID> --file <script>");
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
    console.error("Usage: phantom vm screenshot <VM_ID> [--out <path>]");
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
    console.error("Error: VM_ID required");
    console.error("Usage: phantom vm delete <VM_ID>");
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
