import { sendRequest } from "../lib/api";
import { formatGB, parseCatalog, type Catalog, type CatalogEntry } from "../lib/catalog";
import { RegistryClient, credentialsFor, parseRef } from "../lib/oci";
import { usageError, type Command } from "../command";

// MARK: - image publish
//
// Admin-only: push a local image to the registry, then record it in the
// catalog so users see it. Two steps, because the catalog entry has to record
// the digest the registry actually stored — that digest is what makes a user's
// pull verifiable, so it is read back from the registry rather than computed
// here.
//
// The catalog is `catalog.json` in this repo, so the second step edits a file
// in the checkout and the author commits it. That is one step more than
// rewriting a registry artifact was, and buys the three things a mutable tag
// could not give: a failed read cannot truncate the catalog (there is no read
// of a remote catalog in this path at all), concurrent publishes conflict in
// git instead of silently dropping an entry, and every change to a published
// digest is a commit with an author and a diff.

const DEFAULT_NAMESPACE = process.env.PHANTOM_REGISTRY_NAMESPACE ?? "ghcr.io/phantom-vm";

const DEFAULT_CATALOG_FILE = "catalog.json";

interface PublishOptions {
  imageName: string;
  description?: string;
  tag: string;
  repository?: string;
  catalogFile: string;
  catalogOnly: boolean;
}

function parseArgs(args: string[]): PublishOptions | null {
  const opts: PublishOptions = {
    imageName: "",
    tag: "latest",
    catalogFile: DEFAULT_CATALOG_FILE,
    catalogOnly: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--description") opts.description = args[++i];
    else if (a === "--tag") opts.tag = args[++i]!;
    else if (a === "--repository") opts.repository = args[++i];
    else if (a === "--catalog-file") opts.catalogFile = args[++i]!;
    else if (a === "--catalog-only") opts.catalogOnly = true;
    else if (!a.startsWith("--") && !opts.imageName) opts.imageName = a;
  }
  return opts.imageName ? opts : null;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/// image.ts aggregates this into the admin command set; declaring it here keeps
/// the help text next to the handler that has to honour it.
export const publishCommand: Command = {
  usage: "<name> [--description <text>]",
  description: "Push a local image and list it in the public catalog",
  details: [
    "--description <text>   One-line description for the catalog",
    `--repository <repo>    Target repository (default: ${DEFAULT_NAMESPACE}/<name>)`,
    "--tag <tag>            Tag to push (default: latest)",
    `--catalog-file <path>  Catalog to edit (default: ./${DEFAULT_CATALOG_FILE}, so run this`,
    "                       from the repo checkout)",
    "--catalog-only         Update the catalog entry without re-pushing blobs",
  ],
  multiArgHandler: imagePublish,
};

export async function imagePublish(...args: string[]) {
  const opts = parseArgs(args);
  if (!opts) {
    usageError("image", "publish", publishCommand);
    process.exit(1);
  }

  try {
    await run(opts);
  } catch (err) {
    console.error(`\n✗ Publish failed: ${err instanceof Error ? err.message : err}`);
    process.exit(1);
  }
}

async function run(opts: PublishOptions) {
  const repository = opts.repository ?? `${DEFAULT_NAMESPACE}/${opts.imageName}`;
  const reference = `${repository}:${opts.tag}`;

  const local = await localImage(opts.imageName);
  const registry = parseRef(reference).registry;

  // Resolved here and passed through: the daemon can read a Docker config, but
  // not a Keychain-backed one, and being a GUI app it never sees the shell's
  // PHANTOM_REGISTRY_* either. Fail before a multi-hour upload, not after.
  const creds = await credentialsFor(registry);
  if (!creds && !registry.startsWith("localhost")) {
    throw new Error(
      `no credentials for ${registry} — run 'docker login ${registry}' or set PHANTOM_REGISTRY_USERNAME/PASSWORD`
    );
  }

  console.log(`[1/3] ${opts.catalogOnly ? "Skipping push" : `Pushing ${opts.imageName}`} → ${reference}`);
  if (!opts.catalogOnly) {
    console.log(`      ${formatGB(local.totalSize)} across ${local.layerCount} layers`);
    const res = await sendRequest({
      method: "image.push",
      params: {
        name: opts.imageName,
        reference,
        ...(creds && { username: creds.username, password: creds.password }),
      },
    });
    if (res.error) throw new Error(res.error.message);
    await waitForPush();
  }

  console.log(`[2/3] Reading back the stored manifest digest`);
  const digest = await (await RegistryClient.for(reference)).manifestDigest();
  console.log(`      ${digest}`);

  console.log(`[3/3] Recording it in ${opts.catalogFile}`);
  const catalog = await readCatalogFile(opts.catalogFile);
  const previous = catalog.images.find((i) => i.name === opts.imageName);

  const entry: CatalogEntry = {
    name: opts.imageName,
    description: opts.description ?? previous?.description ?? opts.imageName,
    repository,
    digest,
    compressedSize: local.totalSize,
    diskSize: local.diskSize,
    published: new Date().toISOString().slice(0, 10),
  };

  const next: Catalog = {
    schemaVersion: 1,
    images: [...catalog.images.filter((i) => i.name !== entry.name), entry].sort((a, b) =>
      a.name.localeCompare(b.name)
    ),
  };
  await Bun.write(opts.catalogFile, JSON.stringify(next, null, 2) + "\n");
  console.log(`      ${previous ? "updated" : "added"} '${entry.name}' (${next.images.length} images)`);

  console.log(`\n✓ Pushed '${opts.imageName}' and updated ${opts.catalogFile}.`);
  console.log(`  Commit and push it — users read the catalog from the repo, so`);
  console.log(`  'phantom image pull ${opts.imageName}' resolves only once it lands on main.`);
}

/// The catalog to edit. A missing file is an error rather than an empty
/// catalog: the likely cause is running this outside the checkout, and treating
/// that as "no images yet" would write a catalog with exactly one entry and
/// call it complete.
async function readCatalogFile(path: string): Promise<Catalog> {
  const file = Bun.file(path);
  if (!(await file.exists())) {
    throw new Error(
      `no catalog at '${path}' — run this from the repo checkout, or pass --catalog-file`
    );
  }
  const catalog = parseCatalog(await file.text());
  if (!catalog) {
    throw new Error(`'${path}' is not a readable catalog (expected schemaVersion 1 with an images array)`);
  }
  return catalog;
}

/// Size and layer count of a local image, read from its manifest, plus the disk
/// size the image restores to (from its VM config).
async function localImage(name: string) {
  const dir = `${process.env.HOME}/Library/Application Support/phantom/images/${name}`;
  const manifestFile = Bun.file(`${dir}/manifest.json`);
  if (!(await manifestFile.exists())) {
    throw new Error(`no local image named '${name}' (see 'phantom image list')`);
  }
  const manifest = (await manifestFile.json()) as { layers: { size: number }[] };
  const config = (await Bun.file(`${dir}/config.json`).json()) as { diskSize: number };
  return {
    totalSize: manifest.layers.reduce((sum, l) => sum + l.size, 0),
    layerCount: manifest.layers.length,
    diskSize: config.diskSize,
  };
}

const BAR_WIDTH = 28;

/// Single line, redrawn in place. Only when stdout is a terminal — piped into a
/// file or a CI log, carriage returns just pile up, so there we print each new
/// message on its own line instead.
function renderProgress(fraction: number, message: string, elapsedMs: number) {
  const filled = Math.max(0, Math.min(BAR_WIDTH, Math.round(fraction * BAR_WIDTH)));
  const bar = "█".repeat(filled) + "·".repeat(BAR_WIDTH - filled);
  const pct = `${Math.floor(fraction * 100)}`.padStart(3);
  const mins = Math.floor(elapsedMs / 60_000);
  const secs = Math.floor((elapsedMs % 60_000) / 1000);
  const clock = `${mins}:${`${secs}`.padStart(2, "0")}`;
  const line = `      [${bar}] ${pct}%  ${clock}  ${message}`;
  process.stdout.write(`\r${line.slice(0, 120).padEnd(78)}`);
}

async function waitForPush(maxMs = 6 * 3600_000) {
  const started = Date.now();
  const deadline = started + maxMs;
  const tty = process.stdout.isTTY;
  let lastMessage = "";
  let drew = false;

  while (Date.now() < deadline) {
    const res = await sendRequest({ method: "image.status" });
    const status = res.result as { state?: string; progress?: number; message?: string } | undefined;
    const state = status?.state ?? "";
    const message = status?.message ?? "";

    // Terminal states first: the daemon resets progress to 0 when it finishes,
    // so drawing before this check flashes an empty bar at the very end.
    if (state === "completed" || state === "error") {
      if (tty && drew) {
        if (state === "completed") renderProgress(1, message, Date.now() - started);
        process.stdout.write("\n");
      }
      if (state === "error") throw new Error(message || "push failed");
      return;
    }

    if (tty) {
      renderProgress(status?.progress ?? 0, message, Date.now() - started);
      drew = true;
    } else if (message && message !== lastMessage) {
      const pct = status?.progress != null ? ` ${Math.floor(status.progress * 100)}%` : "";
      console.log(`      ${message}${pct}`);
      lastMessage = message;
    }

    // 1s rather than 5s: the bar should move, and image.status is a cheap read.
    await sleep(1_000);
  }
  throw new Error("push timed out");
}
