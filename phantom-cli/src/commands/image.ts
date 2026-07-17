import { sendRequest } from "../lib/api";

export async function imageList() {
  const [response, statusResponse] = await Promise.all([
    sendRequest({ method: "image.list" }),
    sendRequest({ method: "image.status" }),
  ]);

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  // Only surface a status line while an operation is actively running.
  // completed/error/idle are skipped so a finished op doesn't linger in the
  // listing (and so create-from-image's state can't leak in here).
  const status = statusResponse.result;
  const inProgress = ["saving", "pushing", "pulling"];
  if (status && inProgress.includes(status.state)) {
    const pct = status.progress != null ? ` ${Math.floor(status.progress * 100)}%` : "";
    console.log(`[${status.state}${pct}] ${status.message ?? ""}\n`);
  }

  const images = (response.result?.images as any[]) ?? [];

  if (images.length === 0) {
    console.log(
      "No images found. Use 'phantom image save <vmId> <name>' to save a VM as an image."
    );
    return;
  }

  for (const img of images) {
    const sizeGB = (img.totalSize / 1024 / 1024 / 1024).toFixed(1);
    console.log(`${img.name.padEnd(25)} ${sizeGB}GB`);
  }
}

export async function imageDelete(name?: string) {
  if (!name) {
    console.error("Usage: phantom image delete <name>");
    process.exit(1);
  }

  const response = await sendRequest({
    method: "image.delete",
    params: { name },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Deleted image '${name}'`);
}

export async function imageSave(...args: string[]) {
  if (args.length < 2) {
    console.error("Usage: phantom image save <vmId> <imageName>");
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
  console.log("Use 'phantom image list' to check progress.");
}

export async function imagePush(...args: string[]) {
  let name: string | undefined;
  let reference: string | undefined;
  let username: string | undefined;
  let password: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--username" && i + 1 < args.length) {
      username = args[++i];
    } else if (args[i] === "--password" && i + 1 < args.length) {
      password = args[++i];
    } else if (!name) {
      name = args[i];
    } else if (!reference) {
      reference = args[i];
    }
  }

  if (!name || !reference) {
    console.error("Usage: phantom image push <imageName> <registry/namespace:tag>");
    console.error("  --username <user>    Registry username");
    console.error("  --password <pass>    Registry password");
    process.exit(1);
  }

  const params: Record<string, any> = { name, reference };
  if (username) params.username = username;
  if (password) params.password = password;

  const response = await sendRequest({ method: "image.push", params });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Pushing image '${name}' to ${reference}...`);
  console.log("Use 'phantom image list' to check progress.");
}

export async function imagePull(...args: string[]) {
  let reference: string | undefined;
  let name: string | undefined;
  let username: string | undefined;
  let password: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--name" && i + 1 < args.length) {
      name = args[++i];
    } else if (args[i] === "--username" && i + 1 < args.length) {
      username = args[++i];
    } else if (args[i] === "--password" && i + 1 < args.length) {
      password = args[++i];
    } else if (!reference) {
      reference = args[i];
    }
  }

  if (!reference) {
    console.error("Usage: phantom image pull <registry/namespace:tag> [--name <localName>]");
    console.error("  --name <name>        Local image name (default: derived from reference)");
    console.error("  --username <user>     Registry username");
    console.error("  --password <pass>     Registry password");
    process.exit(1);
  }

  const params: Record<string, any> = { reference };
  if (name) params.name = name;
  if (username) params.username = username;
  if (password) params.password = password;

  const response = await sendRequest({ method: "image.pull", params });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Pulling image from ${reference}...`);
  console.log("Use 'phantom image list' to check progress.");
}
