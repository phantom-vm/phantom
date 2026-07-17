import { sendRequest, sendStreamingRequest, type VM } from "../lib/api";

export async function vmCreate(...args: string[]) {
  // Parse flags
  let fromVm: string | undefined;
  let fromIpsw: string | undefined;
  let fromImage: string | undefined;
  let rm = false;
  let commandArgs: string[] = [];

  // Split on -- separator
  const dashDashIndex = args.indexOf("--");
  const flagArgs = dashDashIndex === -1 ? args : args.slice(0, dashDashIndex);
  if (dashDashIndex !== -1) {
    commandArgs = args.slice(dashDashIndex + 1);
  }

  for (let i = 0; i < flagArgs.length; i++) {
    if (flagArgs[i] === "--from-vm" && i + 1 < flagArgs.length) {
      fromVm = flagArgs[i + 1];
      i++;
    } else if (flagArgs[i] === "--from-ipsw" && i + 1 < flagArgs.length) {
      fromIpsw = flagArgs[i + 1];
      i++;
    } else if (flagArgs[i] === "--from-image" && i + 1 < flagArgs.length) {
      fromImage = flagArgs[i + 1];
      i++;
    } else if (flagArgs[i] === "--rm") {
      rm = true;
    }
  }

  // Validate flags
  const sources = [fromVm, fromIpsw, fromImage].filter(Boolean);
  if (sources.length === 0) {
    console.error(
      "Error: Must specify one of --from-vm, --from-ipsw, or --from-image"
    );
    console.error("Usage:");
    console.error("  phantom vm create --from-ipsw <ipsw-id>");
    console.error("  phantom vm create --from-vm <vm-id>");
    console.error("  phantom vm create --from-image <image-name>");
    console.error("  phantom vm create --from-vm <vm-id> --rm -- <command>");
    process.exit(1);
  }

  if (sources.length > 1) {
    console.error(
      "Error: Cannot specify multiple sources (--from-vm, --from-ipsw, --from-image)"
    );
    process.exit(1);
  }

  if (rm && !fromVm) {
    console.error("Error: --rm requires --from-vm");
    process.exit(1);
  }

  if (rm && commandArgs.length === 0) {
    console.error("Error: --rm requires a command after --");
    console.error("Usage: phantom vm create --from-vm <vm-id> --rm -- <command>");
    process.exit(1);
  }

  // Ephemeral VM: clone → start → exec → delete
  if (rm && fromVm) {
    await runEphemeral(fromVm, commandArgs);
    return;
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
  console.log(
    "\nNote: VM creation happens in the background. Use 'phantom vm list' to check status."
  );
}

async function runEphemeral(sourceVmId: string, commandArgs: string[]) {
  const command = commandArgs.join(" ");

  // 1. Clone
  console.error(`Cloning VM ${sourceVmId}...`);
  const createResponse = await sendRequest({
    method: "vm.create",
    params: { sourceVmId },
  });

  if (createResponse.error) {
    console.error(`Error cloning VM: ${createResponse.error.message}`);
    process.exit(1);
  }

  const vmId = createResponse.result?.vmId as string;
  console.error(`Created ephemeral VM ${vmId}`);

  // Ensure cleanup on exit
  let exitCode = 1;
  try {
    // 2. Start
    console.error(`Starting VM ${vmId}...`);
    const startResponse = await sendRequest(
      { method: "vm.start", params: { vmId } },
      { timeoutMs: 120_000 }
    );

    if (startResponse.error) {
      console.error(`Error starting VM: ${startResponse.error.message}`);
      return;
    }

    console.error(`VM ${vmId} running`);

    // 3. Execute command with streaming output (wait for agent to be ready)
    console.error(`Executing: ${command}`);
    const { exitCode: code } = await sendStreamingRequest(
      {
        method: "vm.execStream",
        params: { vmId, command, waitForAgent: true },
      },
      (chunk) => {
        if (chunk.type === "stdout" && chunk.data) process.stdout.write(chunk.data);
        if (chunk.type === "stderr" && chunk.data) process.stderr.write(chunk.data);
      }
    );
    exitCode = code;
  } finally {
    // 4. Always delete
    console.error(`Deleting ephemeral VM ${vmId}...`);
    await sendRequest({ method: "vm.delete", params: { vmId } });
    console.error(`Deleted ${vmId}`);
    process.exit(exitCode);
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
    console.log("No VMs. Run 'phantom vm create --from-ipsw <IPSW_ID>' to create one.");
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
