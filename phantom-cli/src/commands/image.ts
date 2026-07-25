import { sendRequest } from "../lib/api";
import { imageBuild } from "./build";
import { imagePublish } from "./publish";
import {
  fetchCatalog,
  formatGB,
  pullReference,
  resolve,
  type Catalog,
} from "../lib/catalog";
import type { Command } from "../command";

export async function imageList() {
  const [response, statusResponse, catalog] = await Promise.all([
    sendRequest({ method: "image.list" }),
    sendRequest({ method: "image.status" }),
    fetchCatalog(),
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
  const local = new Map<string, number>(images.map((i) => [i.name, i.totalSize]));

  // Catalog images first, marked with whether they're already here, then
  // anything local the catalog doesn't know about (locally built or pulled).
  for (const entry of catalog?.images ?? []) {
    const mark = local.has(entry.name) ? "  (Downloaded)" : "";
    console.log(`${entry.name.padEnd(25)} ${formatGB(entry.compressedSize).padStart(7)}${mark}`);
    console.log(`${" ".repeat(25)} ${entry.description}`);
    local.delete(entry.name);
  }

  if (local.size > 0) {
    if (catalog) console.log("\nLocal only:");
    for (const [name, totalSize] of local) {
      console.log(`${name.padEnd(25)} ${formatGB(totalSize).padStart(7)}`);
    }
  }

  if (!catalog && local.size === 0) {
    console.log("No local images, and the image catalog could not be reached.");
    return;
  }

  if (catalog && images.length === 0) {
    console.log("\nPull one with 'phantom image pull <name>'.");
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
    console.error("Usage: phantom image pull <name | registry/namespace:tag> [--name <localName>]");
    console.error("  <name>               Catalog image, e.g. 'xcode-26-6' (see 'phantom image list')");
    console.error("  --name <name>        Local image name (default: derived from reference)");
    console.error("  --username <user>     Registry username");
    console.error("  --password <pass>     Registry password");
    process.exit(1);
  }

  // A bare name means the catalog. Resolving it there pins the pull to the
  // published manifest digest, which is what makes it verifiable.
  if (!reference.includes("/")) {
    const catalog = await fetchCatalog();
    if (!catalog) {
      console.error(`Error: could not reach the image catalog to resolve '${reference}'`);
      console.error("Pass a full registry reference to pull without the catalog.");
      process.exit(1);
    }
    const entry = resolve(catalog, reference);
    if (!entry) {
      console.error(`Error: no image named '${reference}' in the catalog`);
      console.error(`Available: ${catalog.images.map((i) => i.name).join(", ")}`);
      process.exit(1);
    }
    name ??= entry.name;
    reference = pullReference(entry);
    console.log(`${entry.name} — ${entry.description}`);
    console.log(`${formatGB(entry.compressedSize)} to download, ${formatGB(entry.diskSize)} on disk\n`);
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

// Base commands, wired up by both CLI builds (see registry.ts).
export const commands: Record<string, Command> = {
  list: { usage: "", description: "List local images (default with no subcommand)", handler: imageList as Command["handler"] },
  save: { usage: "<vmId> <name>", description: "Save a stopped VM as a local image", multiArgHandler: imageSave },
  push: { usage: "<name> <registry:tag>", description: "Push a local image to an OCI registry", multiArgHandler: imagePush },
  pull: { usage: "<registry:tag> [--name <localName>]", description: "Pull an image from an OCI registry", multiArgHandler: imagePull },
  delete: { usage: "<name>", description: "Delete a local image", handler: imageDelete as Command["handler"] },
};

// Only imported by the admin entry (src/main.ts) — see the comment on
// vm.ts's adminCommands for why this is a separate export rather than a
// runtime-gated one.
export const adminCommands: Record<string, Command> = {
  build: {
    usage: "<name> [options]",
    description: "IPSW → agent install → provision → save, unattended",
    multiArgHandler: imageBuild,
  },
  publish: {
    usage: "<name> [--description <text>]",
    description: "Push a local image and list it in the public catalog",
    multiArgHandler: imagePublish,
  },
};
