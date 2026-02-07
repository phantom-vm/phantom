import { sendRequest, type VM } from "../lib/api";

export async function vmList() {
  const response = await sendRequest({ method: "vms.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const vms = response.result?.vms as VM[] || [];

  if (vms.length === 0) {
    console.log("No VMs. Run 'phantom run <IMAGE>' to create one.");
    return;
  }

  console.log("VM ID                STATE");
  for (const vm of vms) {
    console.log(`${vm.id.padEnd(20)} ${vm.state}`);
  }
}

export async function vmRun(imageId: string) {
  if (!imageId) {
    console.error("Error: IMAGE required");
    console.error("Usage: phantom run <IMAGE>");
    process.exit(1);
  }

  console.log(`Creating VM from image ${imageId}...`);

  const response = await sendRequest({
    method: "vms.create",
    params: { imageId },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "VM creation started");
  console.log("\nNote: VM creation happens in the background. Use 'phantom vm list' to check status.");
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
