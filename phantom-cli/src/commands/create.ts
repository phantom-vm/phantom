import { sendRequest } from "../lib/api";

export async function vmCreate(...args: string[]) {
  // Parse flags
  let fromVm: string | undefined;
  let fromIpsw: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--from-vm" && i + 1 < args.length) {
      fromVm = args[i + 1];
      i++;
    } else if (args[i] === "--from-ipsw" && i + 1 < args.length) {
      fromIpsw = args[i + 1];
      i++;
    }
  }

  // Validate flags
  if (!fromVm && !fromIpsw) {
    console.error("Error: Must specify either --from-vm or --from-ipsw");
    console.error("Usage:");
    console.error("  phantom create --from-ipsw <ipsw-id>");
    console.error("  phantom create --from-vm <vm-id>");
    process.exit(1);
  }

  if (fromVm && fromIpsw) {
    console.error("Error: Cannot specify both --from-vm and --from-ipsw");
    process.exit(1);
  }

  // Create from IPSW
  if (fromIpsw) {
    console.log(`Creating VM from IPSW ${fromIpsw}...`);

    const response = await sendRequest({
      method: "vms.create",
      params: { imageId: fromIpsw },
    });

    if (response.error) {
      console.error(`Error: ${response.error.message}`);
      process.exit(1);
    }

    console.log(response.result?.message || "VM creation started");
    console.log("\nNote: VM creation happens in the background. Use 'phantom list' to check status.");
    return;
  }

  // Clone from VM
  if (fromVm) {
    console.log(`Cloning VM ${fromVm}...`);

    const response = await sendRequest({
      method: "vms.clone",
      params: { vmId: fromVm },
    });

    if (response.error) {
      console.error(`Error: ${response.error.message}`);
      process.exit(1);
    }

    console.log(response.result?.message || "VM cloning started");
    console.log("\nNote: VM cloning happens in the background. Use 'phantom list' to check status.");
    return;
  }
}
