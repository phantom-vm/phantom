import { sendRequest } from "../lib/api";

export async function imageSave(...args: string[]) {
  if (args.length < 2) {
    console.error("Usage: phantom save <vmId> <imageName>");
    process.exit(1);
  }

  const vmId = args[0];
  const name = args[1];

  const response = await sendRequest({
    method: "image.save",
    params: { vmId, name },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Saving VM '${vmId}' as image '${name}'...`);
  console.log("Use 'phantom images' to check progress.");
}
