import { sendRequest } from "../lib/api";
import { buildCommand } from "./build";
import { publishCommand } from "./publish";
import {
  fetchCatalog,
  formatGB,
  pullReference,
  resolve,
  type Catalog,
} from "../lib/catalog";
import { usageError, type Command } from "../command";

interface LocalImage {
  name: string;
  totalSize: number;
  /// Present only for images pulled since the daemon started recording it.
  pulledFrom?: { reference: string; digest: string; pulledAt: string };
}

/// Whether a local image is the one the catalog currently points at. "unknown"
/// covers an image built locally and one pulled before pulls left a record —
/// neither can be judged, and neither should be reported as out of date.
function compareToCatalog(image: LocalImage, catalogDigest: string): "current" | "stale" | "unknown" {
  if (!image.pulledFrom) return "unknown";
  return image.pulledFrom.digest === catalogDigest ? "current" : "stale";
}

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

  const images = (response.result?.images as LocalImage[]) ?? [];
  const local = new Map<string, LocalImage>(images.map((i) => [i.name, i]));

  // Catalog images first, marked with whether they're already here, then
  // anything local the catalog doesn't know about (locally built or pulled).
  let updatable = false;
  for (const entry of catalog?.images ?? []) {
    const have = local.get(entry.name);
    let mark = "";
    if (have) {
      switch (compareToCatalog(have, entry.digest)) {
        case "current":
          mark = "  (Downloaded)";
          break;
        case "stale":
          mark = "  (update available)";
          updatable = true;
          break;
        case "unknown":
          // Saved locally, or pulled before pulls recorded their digest.
          mark = "  (Downloaded, origin unknown)";
          break;
      }
    }
    console.log(`${entry.name.padEnd(25)} ${formatGB(entry.compressedSize).padStart(7)}${mark}`);
    console.log(`${" ".repeat(25)} ${entry.description}`);
    local.delete(entry.name);
  }

  if (local.size > 0) {
    if (catalog) console.log("\nLocal only:");
    for (const [name, image] of local) {
      console.log(`${name.padEnd(25)} ${formatGB(image.totalSize).padStart(7)}`);
    }
  }

  if (updatable) {
    console.log("\nUpdate with 'phantom image pull <name>'.");
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
    console.error("Error: image name required");
    console.error("");
    usage("delete");
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
  const positional = args.filter((a) => !a.startsWith("--"));
  const replace = args.includes("--replace");

  if (positional.length < 2) {
    console.error("Error: a VM id and an image name are both required");
    console.error("");
    usage("save");
    process.exit(1);
  }

  const vmId = positional[0];
  const name = positional[1];

  const response = await sendRequest({
    method: "image.save",
    params: { vmId, name, replace },
  });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  console.log(`Saving VM '${vmId}' as image '${name}'${replace ? " (replacing)" : ""}...`);
  // A replacement is built beside the existing image and swapped in at the end,
  // so the name is in `image list` throughout — watch the daemon log instead.
  console.log(
    replace
      ? "The old image stays in place until the new one is complete."
      : "Use 'phantom image list' to check progress."
  );
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
    console.error("Error: an image name and a target reference are both required");
    console.error("");
    usage("push");
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
  let force = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--name" && i + 1 < args.length) {
      name = args[++i];
    } else if (args[i] === "--username" && i + 1 < args.length) {
      username = args[++i];
    } else if (args[i] === "--password" && i + 1 < args.length) {
      password = args[++i];
    } else if (args[i] === "--force") {
      force = true;
    } else if (!reference) {
      reference = args[i];
    }
  }

  if (!reference) {
    console.error("Error: an image name or a registry reference is required");
    console.error("");
    usage("pull");
    process.exit(1);
  }

  // A bare name means the catalog. Resolving it there pins the pull to the
  // published manifest digest, which is what makes it verifiable.
  let catalogDigest: string | undefined;
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
    catalogDigest = entry.digest;
    reference = pullReference(entry);
    console.log(`${entry.name} — ${entry.description}`);
    console.log(`${formatGB(entry.compressedSize)} to download, ${formatGB(entry.diskSize)} on disk\n`);
  }

  // Already present? Decide between doing nothing, updating, and refusing.
  const replace = await resolveExisting(name, catalogDigest, force);

  const params: Record<string, any> = { reference };
  if (name) params.name = name;
  if (replace) params.replace = true;
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

/// Whether the daemon should replace a local image of this name — exiting
/// instead when there is nothing to do, or when replacing would be a guess.
///
/// Replacing deletes the local copy before downloading, so a name being
/// "already there" is never overwritten without either a digest that proves it
/// is out of date or an explicit --force.
async function resolveExisting(
  name: string | undefined,
  catalogDigest: string | undefined,
  force: boolean
): Promise<boolean> {
  if (!name) return force;

  const res = await sendRequest({ method: "image.list" });
  const existing = ((res.result?.images as LocalImage[]) ?? []).find((i) => i.name === name);
  if (!existing) return false;

  if (force) {
    console.log(`Replacing local image '${name}'.\n`);
    return true;
  }

  const state = catalogDigest ? compareToCatalog(existing, catalogDigest) : "unknown";

  if (state === "current") {
    console.log(`'${name}' is already the published image — nothing to do.`);
    process.exit(0);
  }

  if (state === "unknown") {
    console.error(`Error: '${name}' already exists locally and cannot be compared to the catalog`);
    console.error(
      existing.pulledFrom
        ? "It was pulled from a different reference."
        : "It was built locally, or pulled before pulls recorded their origin."
    );
    console.error(`Replace it with 'phantom image pull ${name} --force', or delete it first.`);
    process.exit(1);
  }

  const pulledAt = existing.pulledFrom?.pulledAt?.slice(0, 10) ?? "unknown date";
  console.log(`Updating '${name}' (local copy pulled ${pulledAt} is no longer the published one).`);
  console.log("The local copy is deleted first, so a failed pull leaves nothing behind.\n");
  return true;
}

export const commands: Record<string, Command> = {
  list: { usage: "", description: "List local images (default with no subcommand)", handler: imageList as Command["handler"] },
  save: {
    usage: "<vmId> <name> [--replace]",
    description: "Save a stopped VM as a local image",
    details: ["--replace  Overwrite an existing image of the same name"],
    multiArgHandler: imageSave,
  },
  push: {
    usage: "<name> <registry:tag>",
    description: "Push a local image to an OCI registry",
    details: [
      "--username <user>  Registry username",
      "--password <pass>  Registry password",
    ],
    multiArgHandler: imagePush,
  },
  pull: {
    usage: "<name | registry:tag> [options]",
    description: "Pull an image from the catalog or an OCI registry",
    details: [
      "<name>             Catalog image, e.g. 'xcode-26-6' (see 'phantom image list')",
      "--name <name>      Local image name (default: derived from the reference)",
      "--force            Replace an image that is already present",
      "--username <user>  Registry username",
      "--password <pass>  Registry password",
    ],
    multiArgHandler: imagePull,
  },
  delete: { usage: "<name>", description: "Delete a local image", handler: imageDelete as Command["handler"] },
};

// Image authoring: main.ts registers these only under PHANTOM_ADMIN_MODE.
// Both are declared in the module that implements them, so the option detail
// and the parser that enforces it stay in one file.
export const adminCommands: Record<string, Command> = {
  build: buildCommand,
  publish: publishCommand,
};

/// A handler's usage-error path — same text as `phantom help image <name>`.
const usage = (name: string) => usageError("image", name, commands[name] ?? adminCommands[name]!);
