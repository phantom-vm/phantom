import { sendRequest, type Image } from "../lib/api";

export async function ipswList() {
  const response = await sendRequest({ method: "images.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const images = response.result?.images as Image[] || [];

  if (images.length === 0) {
    console.log("No IPSW images available. Run 'phantom ipsw pull' to download one.");
    return;
  }

  console.log("IPSW IMAGES");
  for (const image of images) {
    const sizeGB = (image.size / 1024 / 1024 / 1024).toFixed(2);
    console.log(`${image.id.padEnd(20)} ${sizeGB}GB`);
  }
}

export async function ipswPull() {
  console.log("Starting IPSW download...");

  const response = await sendRequest({ method: "images.pull" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "Download started");
  console.log("\nNote: Download happens in the background. Use 'phantom ipsw list' to check when it's available.");
}
