import { sendRequest, type IPSW } from "../lib/api";
import type { Command } from "../command";

// This whole module is admin-only — it's imported exclusively by the admin
// entry (src/main.ts). The user entry (src/main-user.ts) never imports it,
// so it and its network calls to the IPSW catalog are absent from that
// build (plain unused-module elimination, not a runtime flag).

// IPSW catalog: VirtualBuddy's curated manifest, maintained in a public git
// repo (auditable history). The catalog only *points* — the daemon refuses
// any download URL outside Apple's CDN, and the restore image signature is
// verified at install time.
const CATALOG_URL =
  "https://raw.githubusercontent.com/insidegui/VirtualBuddy/main/data/ipsws_v2.json";

interface CatalogImage {
  build: string;
  version: string;
  name: string;
  channel: string; // "regular" | "devbeta" | ...
  downloadSize: number;
  url: string;
}

async function fetchCatalog(): Promise<CatalogImage[] | null> {
  try {
    const res = await fetch(CATALOG_URL, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) return null;
    const data = (await res.json()) as { restoreImages?: CatalogImage[] };
    return data.restoreImages ?? null;
  } catch {
    return null;
  }
}

/// Local IPSWs from the daemon, keyed by build id (filename stem)
async function localBuilds(): Promise<Map<string, IPSW>> {
  const response = await sendRequest({ method: "ipsw.list" });
  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }
  const ipsws = (response.result?.ipsws as IPSW[]) || [];
  return new Map(ipsws.map((i) => [i.id, i]));
}

function printLocalOnly(local: Map<string, IPSW>) {
  if (local.size === 0) {
    console.log("No IPSWs downloaded. Run 'phantom ipsw pull [version]' to download one.");
    return;
  }
  console.log("IPSWS");
  for (const ipsw of local.values()) {
    const sizeGB = (ipsw.size / 1024 / 1024 / 1024).toFixed(2);
    console.log(`${ipsw.id.padEnd(20)} ${sizeGB}GB`);
  }
}

export async function ipswList(...args: string[]) {
  const includeBetas = args.includes("--include-betas");
  const [catalog, local] = await Promise.all([fetchCatalog(), localBuilds()]);

  if (!catalog) {
    console.error("Warning: could not fetch IPSW catalog, showing local IPSWs only\n");
    printLocalOnly(local);
    return;
  }

  // Catalog is newest-first; list ascending like `xcodes list`
  const entries = catalog
    .filter((e) => includeBetas || e.channel === "regular")
    .reverse();

  for (const e of entries) {
    const name = e.name.replace(/^macOS /, "");
    const size = `${(e.downloadSize / 1e9).toFixed(1)}GB`;
    const mark = local.has(e.build) ? "  (Downloaded)" : "";
    console.log(`${`${name} (${e.build})`.padEnd(44)} ${size.padStart(7)}${mark}`);
  }
  if (!includeBetas) {
    console.log("\nShowing the release channel. Use --include-betas to list beta builds.");
  }
}

/// Match a user query ("26.3", "26.3.1", build id) against the catalog
function resolveQuery(catalog: CatalogImage[], query: string): CatalogImage[] {
  const q = query.toLowerCase();
  const byBuild = catalog.filter((e) => e.build.toLowerCase() === q);
  if (byBuild.length > 0) return byBuild;

  const norm = (v: string) => v.replace(/(\.0)+$/, "");
  const byVersion = catalog.filter((e) => norm(e.version) === norm(query));
  // A version can match a release plus its betas — prefer the release
  const releases = byVersion.filter((e) => e.channel === "regular");
  return releases.length > 0 ? releases : byVersion;
}

export async function ipswPull(query?: string) {
  if (query) {
    const catalog = await fetchCatalog();
    if (!catalog) {
      console.error("Error: could not fetch IPSW catalog");
      process.exit(1);
    }
    const matches = resolveQuery(catalog, query);
    if (matches.length === 0) {
      console.error(`No IPSW found for '${query}'. See 'phantom ipsw list'.`);
      process.exit(1);
    }
    if (matches.length > 1) {
      console.error(`'${query}' is ambiguous:`);
      for (const m of matches) console.error(`  ${m.name} (${m.build})`);
      console.error("Pull by build id instead.");
      process.exit(1);
    }

    const target = matches[0]!;
    const local = await localBuilds();
    if (local.has(target.build)) {
      console.log(`${target.name} (${target.build}) is already downloaded.`);
      return;
    }

    console.log(`Pulling ${target.name} (${target.build}), ${(target.downloadSize / 1e9).toFixed(1)}GB...`);
    const response = await sendRequest({
      method: "ipsw.pull",
      params: { url: target.url, build: target.build },
    });
    if (response.error) {
      console.error(`Error: ${response.error.message}`);
      process.exit(1);
    }
    await pollDownload();
    return;
  }

  // No argument: the daemon resolves the latest supported restore image via
  // Apple's own API (VZMacOSRestoreImage.latestSupported)
  const preCheck = await sendRequest({ method: "ipsw.status" });
  if (preCheck.result?.state === "downloaded") {
    console.log("IPSW already downloaded. Use 'phantom ipsw list' to see it, or pull a specific version.");
    return;
  }

  const response = await sendRequest({ method: "ipsw.pull" });
  if (response.error) {
    console.error(`Error: ${response.error.message}`);
    process.exit(1);
  }
  await pollDownload();
}

async function pollDownload() {
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

export const commands: Record<string, Command> = {
  list: { usage: "[--include-betas]", description: "List downloadable macOS restore images", multiArgHandler: ipswList },
  pull: { usage: "[version|build]", description: "Download one (default: latest supported)", handler: ipswPull as Command["handler"] },
};
