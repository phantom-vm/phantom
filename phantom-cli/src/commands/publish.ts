import { sendRequest } from "../lib/api";
import {
  CATALOG_LAYER_TYPE,
  CATALOG_REFERENCE,
  fetchCatalog,
  formatGB,
  type Catalog,
  type CatalogEntry,
} from "../lib/catalog";
import { RegistryClient, pushArtifact } from "../lib/oci";

// MARK: - image publish
//
// Admin-only: push a local image to the registry, then rewrite the catalog so
// users see it. Two steps, because the catalog entry has to record the digest
// the registry actually stored — that digest is what makes a user's pull
// verifiable, so it is read back from the registry rather than computed here.

const DEFAULT_NAMESPACE = process.env.PHANTOM_REGISTRY_NAMESPACE ?? "ghcr.io/phantom-vm";

interface PublishOptions {
  imageName: string;
  description?: string;
  tag: string;
  repository?: string;
  catalogOnly: boolean;
}

function parseArgs(args: string[]): PublishOptions | null {
  const opts: PublishOptions = { imageName: "", tag: "latest", catalogOnly: false };
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--description") opts.description = args[++i];
    else if (a === "--tag") opts.tag = args[++i]!;
    else if (a === "--repository") opts.repository = args[++i];
    else if (a === "--catalog-only") opts.catalogOnly = true;
    else if (!a.startsWith("--") && !opts.imageName) opts.imageName = a;
  }
  return opts.imageName ? opts : null;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function imagePublish(...args: string[]) {
  const opts = parseArgs(args);
  if (!opts) {
    console.error("Usage: phantom image publish <name> [options]");
    console.error("  --description <text>   One-line description for the catalog");
    console.error(`  --repository <repo>    Target repository (default: ${DEFAULT_NAMESPACE}/<name>)`);
    console.error("  --tag <tag>            Tag to push (default: latest)");
    console.error("  --catalog-only         Re-publish the catalog entry without re-pushing blobs");
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
  console.log(`[1/3] ${opts.catalogOnly ? "Skipping push" : `Pushing ${opts.imageName}`} → ${reference}`);
  if (!opts.catalogOnly) {
    console.log(`      ${formatGB(local.totalSize)} across ${local.layerCount} layers`);
    const res = await sendRequest({ method: "image.push", params: { name: opts.imageName, reference } });
    if (res.error) throw new Error(res.error.message);
    await waitForPush();
  }

  console.log(`[2/3] Reading back the stored manifest digest`);
  const digest = await (await RegistryClient.for(reference)).manifestDigest();
  console.log(`      ${digest}`);

  console.log(`[3/3] Updating the catalog at ${CATALOG_REFERENCE}`);
  const entry: CatalogEntry = {
    name: opts.imageName,
    description: opts.description ?? (await existingDescription(opts.imageName)) ?? opts.imageName,
    repository,
    digest,
    compressedSize: local.totalSize,
    diskSize: local.diskSize,
    published: new Date().toISOString().slice(0, 10),
  };

  const catalog = (await fetchCatalog()) ?? { schemaVersion: 1 as const, images: [] };
  const next: Catalog = {
    schemaVersion: 1,
    images: [...catalog.images.filter((i) => i.name !== entry.name), entry].sort((a, b) =>
      a.name.localeCompare(b.name)
    ),
  };

  const body = new TextEncoder().encode(JSON.stringify(next, null, 2) + "\n");
  await pushArtifact(CATALOG_REFERENCE, body, CATALOG_LAYER_TYPE);

  console.log(`\n✓ Published '${opts.imageName}' — users can now run 'phantom image pull ${opts.imageName}'`);
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

/// Keep a previously published description when this run doesn't supply one.
async function existingDescription(name: string): Promise<string | undefined> {
  const catalog = await fetchCatalog();
  return catalog?.images.find((i) => i.name === name)?.description;
}

async function waitForPush(maxMs = 6 * 3600_000) {
  const deadline = Date.now() + maxMs;
  let lastMessage = "";
  while (Date.now() < deadline) {
    const res = await sendRequest({ method: "image.status" });
    const status = res.result as { state?: string; progress?: number; message?: string } | undefined;
    const state = status?.state ?? "";
    if (status?.message && status.message !== lastMessage) {
      const pct = status.progress != null ? ` ${Math.floor(status.progress * 100)}%` : "";
      console.log(`      ${status.message}${pct}`);
      lastMessage = status.message;
    }
    if (state === "completed") return;
    if (state === "error") throw new Error(status?.message ?? "push failed");
    await sleep(5_000);
  }
  throw new Error("push timed out");
}
