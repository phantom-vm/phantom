import { pullArtifact } from "./oci";

// The image catalog: what `phantom image list` shows a machine that has pulled
// nothing yet, and what turns `phantom image pull xcode-26-6` into a registry
// reference.
//
// It lives in the same registry as the images, as a one-layer OCI artifact.
// That keeps hosting to a single dependency, and reads are anonymous, so a
// fresh install can browse before it has credentials.
//
// The catalog only *points*, like the IPSW catalog does: every entry carries the
// image's manifest digest, and pulls go by digest, so a tampered registry can't
// substitute an image — the daemon verifies the manifest against that digest and
// every layer against its own.

export const CATALOG_REFERENCE =
  process.env.PHANTOM_CATALOG ?? "ghcr.io/phantom-vm/catalog:latest";

export const CATALOG_LAYER_TYPE = "application/vnd.monk-studio.phantom.catalog.v1+json";

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

export async function fetchCatalog(): Promise<Catalog | null> {
  try {
    const data = await pullArtifact(CATALOG_REFERENCE);
    const parsed = JSON.parse(new TextDecoder().decode(data)) as Catalog;
    if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.images)) return null;
    return parsed;
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
