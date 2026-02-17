import { sendRequest, type VM } from "../lib/api";

export async function vmList() {
  const response = await sendRequest({ method: "vms.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const vms = response.result?.vms as VM[] || [];

  if (vms.length === 0) {
    console.log("No VMs. Run 'phantom create --from-ipsw <IPSW_ID>' to create one.");
    return;
  }

  console.log("VM ID                STATE");
  for (const vm of vms) {
    console.log(`${vm.id.padEnd(20)} ${vm.state}`);
  }
}

export async function vmRun(ipswId: string) {
  if (!ipswId) {
    console.error("Error: IPSW_ID required");
    console.error("Usage: phantom run <IPSW_ID>");
    process.exit(1);
  }

  console.log(`Creating VM from IPSW ${ipswId}...`);

  const response = await sendRequest({
    method: "vms.create",
    params: { ipswId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  console.log("\nNote: VM creation happens in the background. Use 'phantom vm list' to check status.");
}

export async function vmExec(...args: string[]) {
  // Parse: <vm-id> -- <command> [args...]
  const dashDashIndex = args.indexOf("--");
  if (dashDashIndex === -1 || dashDashIndex === 0) {
    console.error("Usage: phantom exec <VM_ID> -- <command> [args...]");
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
      method: "vms.exec",
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

export async function vmStart(vmId: string) {
  if (!vmId) {
    console.error("Error: VM_ID required");
    console.error("Usage: phantom start <VM_ID>");
    process.exit(1);
  }

  console.log(`Starting VM ${vmId}...`);

  const response = await sendRequest(
    { method: "vms.start", params: { vmId } },
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
    console.error("Usage: phantom stop <VM_ID>");
    process.exit(1);
  }

  console.log(`Stopping VM ${vmId}...`);

  const response = await sendRequest({
    method: "vms.stop",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} stopped`);
}

export async function vmDisplay(vmId: string) {
  if (!vmId) {
    console.error("Error: VM_ID required");
    console.error("Usage: phantom display <VM_ID>");
    process.exit(1);
  }

  const response = await sendRequest({
    method: "vms.display",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Display opened for VM ${vmId}`);
}

export async function vmDelete(vmId: string) {
  if (!vmId) {
    console.error("Error: VM_ID required");
    console.error("Usage: phantom delete <VM_ID>");
    process.exit(1);
  }

  console.log(`Deleting VM ${vmId}...`);

  const response = await sendRequest({
    method: "vms.delete",
    params: { vmId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`VM ${vmId} deleted`);
}
