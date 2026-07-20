import { sendRequest } from "../lib/api";
import type { Command } from "../command";

export async function health() {
  const response = await sendRequest({ method: "health" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Phantom daemon: ${response.result?.status || "unknown"}`);
  console.log(`Version: ${response.result?.version || "unknown"}`);
}

export const command: Command = { usage: "", description: "Check daemon connectivity", handler: health };
