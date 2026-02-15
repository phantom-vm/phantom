import { sendRequest, type IPSW } from "../lib/api";

export async function ipswList() {
  const response = await sendRequest({ method: "ipsw.list" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  const ipsws = (response.result?.ipsws as IPSW[]) || [];

  if (ipsws.length === 0) {
    console.log("No IPSWs available. Run 'phantom ipsw pull' to download one.");
    return;
  }

  console.log("IPSWS");
  for (const ipsw of ipsws) {
    const sizeGB = (ipsw.size / 1024 / 1024 / 1024).toFixed(2);
    console.log(`${ipsw.id.padEnd(20)} ${sizeGB}GB`);
  }
}

export async function ipswPull() {
  // Check if already downloaded
  const preCheck = await sendRequest({ method: "ipsw.status" });
  if (preCheck.result?.state === "downloaded") {
    console.log("IPSW already downloaded. Use 'phantom ipsw list' to see it.");
    return;
  }

  // Trigger the download
  const response = await sendRequest({ method: "ipsw.pull" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  // Poll for progress
  let lastPct = -1;
  while (true) {
    await Bun.sleep(1000);

    const status = await sendRequest({ method: "ipsw.status" });
    if (status.error) {
      console.error(`Error: ${status.error.message}`);
      process.exit(1);
    }

    const { state, progress, message } = status.result ?? {};

    switch (state) {
      case "fetching":
        if (lastPct === -1) {
          process.stderr.write("Fetching IPSW info...\n");
          lastPct = 0;
        }
        break;

      case "downloading": {
        const pct = Math.floor((progress ?? 0) * 100);
        if (pct !== lastPct) {
          process.stderr.write(`\rDownloading... ${pct}%`);
          lastPct = pct;
        }
        break;
      }

      case "downloaded":
        if (lastPct > 0) {
          process.stderr.write("\rDownloading... 100%\n");
        }
        console.log("Download complete");
        return;

      case "error":
        process.stderr.write("\n");
        console.error(`Download failed: ${message}`);
        process.exit(1);

      case "none":
        console.log("No download in progress");
        return;
    }
  }
}
