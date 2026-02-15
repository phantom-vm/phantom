import { sendRequest } from "../lib/api";

export async function vmCreate(...args: string[]) {
  // Parse flags
  let fromVm: string | undefined;
  let fromIpsw: string | undefined;
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
    } else if (flagArgs[i] === "--rm") {
      rm = true;
    }
  }

  // Validate flags
  if (!fromVm && !fromIpsw) {
    console.error("Error: Must specify either --from-vm or --from-ipsw");
    console.error("Usage:");
    console.error("  phantom create --from-ipsw <ipsw-id>");
    console.error("  phantom create --from-vm <vm-id>");
    console.error("  phantom create --from-vm <vm-id> --rm -- <command>");
    process.exit(1);
  }

  if (fromVm && fromIpsw) {
    console.error("Error: Cannot specify both --from-vm and --from-ipsw");
    process.exit(1);
  }

  if (rm && !fromVm) {
    console.error("Error: --rm requires --from-vm");
    process.exit(1);
  }

  if (rm && commandArgs.length === 0) {
    console.error("Error: --rm requires a command after --");
    console.error("Usage: phantom create --from-vm <vm-id> --rm -- <command>");
    process.exit(1);
  }

  // Ephemeral VM: clone → start → exec → delete
  if (rm && fromVm) {
    await runEphemeral(fromVm, commandArgs);
    return;
  }

  // Regular create
  const params: { ipswId?: string; sourceVmId?: string } = fromIpsw
    ? { ipswId: fromIpsw }
    : { sourceVmId: fromVm };

  const sourceType = fromIpsw ? "IPSW" : "VM";
  const sourceId = fromIpsw || fromVm;

  console.log(`Creating VM from ${sourceType} ${sourceId}...`);

  const response = await sendRequest({
    method: "vms.create",
    params,
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  console.log(
    "\nNote: VM creation happens in the background. Use 'phantom list' to check status."
  );
}

async function runEphemeral(sourceVmId: string, commandArgs: string[]) {
  const command = commandArgs.join(" ");

  // 1. Clone
  console.error(`Cloning VM ${sourceVmId}...`);
  const createResponse = await sendRequest({
    method: "vms.create",
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
      { method: "vms.start", params: { vmId } },
      { timeoutMs: 120_000 }
    );

    if (startResponse.error) {
      console.error(`Error starting VM: ${startResponse.error.message}`);
      return;
    }

    console.error(`VM ${vmId} running`);

    // 3. Execute command (wait for agent to be ready)
    console.error(`Executing: ${command}`);
    const execResponse = await sendRequest(
      {
        method: "vms.exec",
        params: { vmId, command, waitForAgent: true },
      },
      { timeoutMs: 300_000 }
    );

    if (execResponse.error) {
      console.error(`Error executing command: ${execResponse.error.message}`);
      return;
    }

    const { stdout, stderr, exitCode: code } = execResponse.result;
    if (stdout) process.stdout.write(stdout);
    if (stderr) process.stderr.write(stderr);
    exitCode = code;
  } finally {
    // 4. Always delete
    console.error(`Deleting ephemeral VM ${vmId}...`);
    await sendRequest({ method: "vms.delete", params: { vmId } });
    console.error(`Deleted ${vmId}`);
    process.exit(exitCode);
  }
}
