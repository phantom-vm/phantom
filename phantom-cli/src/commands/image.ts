import { sendRequest, type Image } from "../lib/api";

export async function imageList() {
  const response = await sendRequest({ method: "images.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const images = response.result?.images as Image[] || [];

  if (images.length === 0) {
    console.log("No images available. Run 'phantom image pull' to download one.");
    return;
  }

  console.log("IMAGES");
  for (const image of images) {
    const sizeGB = (image.size / 1024 / 1024 / 1024).toFixed(2);
    console.log(`${image.id.padEnd(20)} ${sizeGB}GB`);
  }
}

export async function imagePull() {
  console.log("Starting image download...");

  const response = await sendRequest({ method: "images.pull" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(response.result?.message || "Download started");
  console.log("\nNote: Download happens in the background. Use 'phantom image list' to check when it's available.");
}
