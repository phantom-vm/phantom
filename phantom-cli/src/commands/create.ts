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

  // Build params based on source
  const params: { imageId?: string; sourceVmId?: string } = fromIpsw
    ? { imageId: fromIpsw }
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
  console.log("\nNote: VM creation happens in the background. Use 'phantom list' to check status.");
}
