import { sendRequest } from "../lib/api";

export async function imagesList() {
  const [response, statusResponse] = await Promise.all([
    sendRequest({ method: "images.list" }),
    sendRequest({ method: "images.status" }),
  ]);

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  // Show operation status if active
  const status = statusResponse.result;
  if (status && status.state !== "idle") {
    const pct = status.progress != null ? ` ${Math.floor(status.progress * 100)}%` : "";
    switch (status.state) {
      case "saving":
        console.log(`[saving${pct}] ${status.message ?? ""}`);
        break;
      case "pushing":
        console.log(`[pushing${pct}] ${status.message ?? ""}`);
        break;
      case "pulling":
        console.log(`[pulling${pct}] ${status.message ?? ""}`);
        break;
      case "completed":
        console.log(`[done] ${status.message ?? ""}`);
        break;
      case "error":
        console.log(`[error] ${status.message ?? ""}`);
        break;
    }
    console.log();
  }

  const images = (response.result?.images as any[]) ?? [];

  if (images.length === 0) {
    console.log(
      "No images found. Use 'phantom save <vmId> <name>' to save a VM as an image."
    );
    return;
  }

  console.log("IMAGES");
  for (const img of images) {
    const sizeMB = (img.totalSize / 1024 / 1024).toFixed(1);
    console.log(
      `${img.name.padEnd(25)} ${img.diskChunks} chunks  ${sizeMB}MB`
    );
  }
}

export async function imagesDelete(name?: string) {
  if (!name) {
    console.error("Usage: phantom images delete <name>");
    process.exit(1);
  }

  const response = await sendRequest({
    method: "images.delete",
    params: { name },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Deleted image '${name}'`);
}
