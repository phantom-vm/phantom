// The image catalog: what `phantom image list` shows a machine that has pulled
// nothing yet, and what turns `phantom image pull xcode-26-6` into a registry
// reference.
//
// It is `catalog.json` at the root of this repo, served over HTTPS from
// raw.githubusercontent. Reads are anonymous, so a fresh install can browse
// before it has credentials, and every change to it is a commit with an author
// and a diff — the IPSW catalog this mirrors (`commands/ipsw.ts`) is hosted the
// same way for the same reason.
//
// The catalog only *points*, like that one does: every entry carries the
// image's manifest digest, and pulls go by digest, so a tampered registry can't
// substitute an image — the daemon verifies the manifest against that digest and
// every layer against its own. Trust in the catalog therefore never exceeds
// trust in the digests it names.
//
// (It used to be a one-layer OCI artifact at ghcr.io/phantom-vm/catalog:latest,
// on the reasoning that one host for both images and catalog was one dependency.
// The repo is public and also on GitHub, so that bought nothing, while a
// mutable tag rewritten wholesale cost a truncation hazard on a failed read, no
// concurrency control, and no history.)

export const CATALOG_URL =
  process.env.PHANTOM_CATALOG ??
  "https://raw.githubusercontent.com/phantom-vm/phantom/main/catalog.json";

export interface CatalogEntry {
  /// Local image name this is pulled as, and how users refer to it
  name: string;
  description: string;
  /// Repository without a tag, e.g. "ghcr.io/phantom-vm/xcode-26-6"
  repository: string;
  /// Manifest digest — pulls use this, not the tag
  digest: string;
  /// Sum of the compressed layers, for display
  compressedSize: number;
  /// Uncompressed disk size of the VM the image restores to
  diskSize: number;
  /// ISO date the image was published
  published: string;
}

export interface Catalog {
  schemaVersion: 1;
  images: CatalogEntry[];
}

export function parseCatalog(text: string): Catalog | null {
  try {
    const parsed = JSON.parse(text) as Catalog;
    if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.images)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/// null on anything that isn't a readable catalog — callers degrade to local
/// images rather than failing. Only readers use this: `publish` edits the
/// checked-out file, so no fetch sits in the write path to swallow an error.
export async function fetchCatalog(): Promise<Catalog | null> {
  try {
    const res = await fetch(CATALOG_URL, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) return null;
    return parseCatalog(await res.text());
  } catch {
    return null;
  }
}

export function resolve(catalog: Catalog, name: string): CatalogEntry | undefined {
  return catalog.images.find((i) => i.name === name);
}

/// Reference to pull an entry by: repository pinned to its manifest digest.
export function pullReference(entry: CatalogEntry): string {
  return `${entry.repository}@${entry.digest}`;
}

export const formatGB = (bytes: number) => `${(bytes / 1e9).toFixed(1)}GB`;
