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
/// covers an image built locally, one published from this machine, and one
/// pulled before pulls left a record — none can be judged, and none should be
/// reported as out of date. The listing renders it as plain "(Downloaded)"; the
/// state is kept distinct for `pull`, which must refuse rather than guess.
function compareToCatalog(image: LocalImage, catalogDigest: string): "current" | "stale" | "unknown" {
  if (!image.pulledFrom) return "unknown";
  return image.pulledFrom.digest === catalogDigest ? "current" : "stale";
}

/// What is on this machine. No catalog fetch: the commonest question about
/// images shouldn't need the network, and comparing against what is published
/// is `image catalog`'s job — the same split the GUI has always had between its
/// Local and Catalog tabs.
export async function imageList() {
  const [response, statusResponse] = await Promise.all([
    sendRequest({ method: "image.list" }),
    sendRequest({ method: "image.status" }),
  ]);

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  printInProgress(statusResponse.result);

  const images = (response.result?.images as LocalImage[]) ?? [];
  if (images.length === 0) {
    console.log("No local images. Browse what's published with 'phantom image catalog'.");
    return;
  }

  for (const image of images) {
    console.log(`${image.name.padEnd(25)} ${formatGB(image.totalSize).padStart(7)}`);
  }
}

/// What is published, and how this machine's copies compare. The marks are the
/// reason this fetches: none of them can be derived locally.
export async function imageCatalog() {
  const [response, catalog] = await Promise.all([
    sendRequest({ method: "image.list" }),
    fetchCatalog(),
  ]);

  if (!catalog) {
    console.error("Error: could not reach the image catalog");
    console.error("'phantom image list' shows the images already on this machine.");
    process.exit(1);
  }

  const local = new Map<string, LocalImage>(
    ((response.result?.images as LocalImage[]) ?? []).map((i) => [i.name, i])
  );

  if (catalog.images.length === 0) {
    console.log("The catalog lists no images.");
    return;
  }

  let updatable = false;
  for (const entry of catalog.images) {
    const have = local.get(entry.name);
    let mark = "";
    if (have) {
      // Only a recorded digest that differs from the catalog is worth saying
      // out loud. Everything else is just "you have this" — an unjudgeable
      // origin is not something the reader can act on, and spelling it out
      // made a successful local build or publish look like a failed pull.
      if (compareToCatalog(have, entry.digest) === "stale") {
        mark = "  (update available)";
        updatable = true;
      } else {
        mark = "  (Downloaded)";
      }
    }
    console.log(`${entry.name.padEnd(25)} ${formatGB(entry.compressedSize).padStart(7)}${mark}`);
    console.log(`${" ".repeat(25)} ${entry.description}`);
  }

  console.log(
    updatable
      ? "\nUpdate with 'phantom image pull <name>'."
      : "\nPull one with 'phantom image pull <name>'."
  );
}

/// A status line for an operation that is running — or was cancelled, which is
/// the one finished state worth a line: it deleted whatever it had written, so
/// the listing below is the same listing as before and says nothing about it.
/// completed/error/idle are skipped so a finished op doesn't linger in the
/// listing (and so create-from-image's state can't leak in here).
function printInProgress(status: { state?: string; progress?: number; message?: string } | undefined) {
  if (!status?.state) return;
  if (status.state === "cancelled") {
    console.log(`[cancelled] ${status.message ?? ""}\n`);
    return;
  }
  if (!["saving", "pushing", "pulling"].includes(status.state)) return;
  const pct = status.progress != null ? ` ${Math.floor(status.progress * 100)}%` : "";
  console.log(`[${status.state}${pct}] ${status.message ?? ""}\n`);
}

/// Stop the running save/push/pull. The daemon answers as soon as the transfer
/// is told to stop, so this waits for the state to turn over rather than
/// reporting a cancellation that hasn't happened yet — a chunk in flight has to
/// finish first, and the partial image is deleted after that.
export async function imageCancel() {
  const response = await sendRequest({ method: "image.cancel" });

  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }

  if (response.result?.status !== "cancelling") {
    console.log("No image operation is running.");
    return;
  }

  const operation = response.result.operation as string;
  console.log(`Cancelling image ${operation}...`);

  for (let i = 0; i < 60; i++) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const status = (await sendRequest({ method: "image.status" })).result as
      | { state?: string; message?: string }
      | undefined;
    if (status?.state === "cancelled") {
      console.log(status.message ?? `Image ${operation} cancelled`);
      return;
    }
    // The operation beat the cancel to the finish — say so rather than claim
    // credit for stopping it.
    if (status?.state === "completed" || status?.state === "error") {
      console.log(`The ${operation} finished before it could be cancelled: ${status.message ?? status.state}`);
      return;
    }
  }

  console.log(`Still stopping. Check 'phantom image list' for the ${operation}'s final state.`);
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
  catalog: { usage: "", description: "Browse the published images and what's newer than yours", handler: imageCatalog as Command["handler"] },
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
  cancel: {
    usage: "",
    description: "Stop the running save, push or pull",
    handler: imageCancel as Command["handler"],
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
