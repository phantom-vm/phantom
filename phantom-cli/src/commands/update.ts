import { chmod, rename, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { CliError } from "../errors";
import { VERSION } from "../version";
import type { Command } from "../command";

const REPO = "phantom-vm/phantom";
const ASSET = "phantom-cli";

/**
 * Replaces the running binary with the latest release.
 *
 * There is no signature to check: release.yml signs and notarizes the daemon
 * app but not this binary, so HTTPS to github.com is the whole trust anchor —
 * exactly as much as the curl one-liner in the README that installed it. A
 * checksum fetched from the same API over the same connection would look like
 * more and prove nothing extra.
 */
export async function update(...args: string[]) {
  const force = args.includes("--force");
  const target = selfPath();

  const latest = await latestRelease();
  const current = parse(VERSION);
  const published = parse(latest.version);

  if (!force && published !== null && current !== null) {
    if (compare(published, current) === 0) {
      console.log(`phantom ${VERSION} is the latest release.`);
      return;
    }
    if (compare(published, current) < 0) {
      // A local build ahead of the last release — the normal state on a dev
      // machine. Downgrading it silently would be rude.
      console.log(`phantom ${VERSION} is newer than the latest release (${latest.version}).`);
      console.log("Use 'phantom update --force' to install the release anyway.");
      return;
    }
  }

  console.log(`Updating phantom ${VERSION} → ${latest.version}`);
  const tmp = join(dirname(target), `.phantom-update-${process.pid}`);

  try {
    await download(latest.assetUrl, tmp);
    await chmod(tmp, 0o755);
    // rename(2) over the running binary is fine — this process keeps the old
    // inode it is already executing, and the new file appears at the path
    // atomically, so a concurrent `phantom` never sees a half-written one.
    await rename(tmp, target);
  } catch (error) {
    await unlink(tmp).catch(() => {});
    throw error;
  }

  console.log(`Updated to ${latest.version} at ${target}`);
}

/// Where to write. Guards the case that would otherwise be silent and awful:
/// run from source, process.execPath is the *bun* binary, and "updating"
/// would overwrite the user's bun with a phantom CLI.
function selfPath(): string {
  // Compiled binaries run their entry from a virtual filesystem; a checkout
  // runs it from a real path.
  if (!Bun.main.startsWith("/$bunfs/")) {
    throw new CliError(
      "'phantom update' only works on an installed binary.",
      `This is running from source (${Bun.main}), where the executable is bun itself.`,
      "Build and install with 'bun run install-bin' instead."
    );
  }
  return process.execPath;
}

interface Release {
  version: string;
  assetUrl: string;
}

async function latestRelease(): Promise<Release> {
  let response: Response;
  try {
    response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { accept: "application/vnd.github+json" },
      signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    throw new CliError(
      "Error: could not reach the GitHub API to check for updates.",
      `${error instanceof Error ? error.message : error}`
    );
  }

  if (!response.ok) {
    throw new CliError(
      `Error: GitHub returned ${response.status} looking up the latest release.`,
      response.status === 403
        ? "Unauthenticated API requests are rate limited by IP; try again later."
        : `See https://github.com/${REPO}/releases.`
    );
  }

  const body = (await response.json()) as { tag_name?: string; assets?: { name: string; browser_download_url: string }[] };
  const tag = body.tag_name;
  if (!tag) throw new CliError("Error: the latest release has no tag.");

  // Download from this release's own URL, not `releases/latest/download/`:
  // `latest` could move between the lookup and the fetch, and then the version
  // reported here would not be the binary installed.
  const asset = body.assets?.find((a) => a.name === ASSET);
  if (!asset) {
    throw new CliError(
      `Error: release ${tag} has no '${ASSET}' asset.`,
      `See https://github.com/${REPO}/releases/tag/${tag}.`
    );
  }

  return { version: tag.replace(/^v/, ""), assetUrl: asset.browser_download_url };
}

async function download(url: string, path: string) {
  let response: Response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(600_000) });
  } catch (error) {
    throw new CliError(
      "Error: download failed.",
      `${error instanceof Error ? error.message : error}`
    );
  }

  if (!response.ok || !response.body) {
    throw new CliError(`Error: download failed with HTTP ${response.status}.`);
  }

  const total = Number(response.headers.get("content-length")) || 0;
  let writer;
  try {
    writer = Bun.file(path).writer();
  } catch {
    throw new CliError(
      `Error: cannot write to ${dirname(path)}.`,
      "Install the CLI somewhere you own, e.g. ~/.local/bin — see the README."
    );
  }

  let received = 0;
  let lastPct = -1;
  for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
    writer.write(chunk);
    received += chunk.length;
    if (!total) continue;
    const pct = Math.floor((received / total) * 100);
    if (pct !== lastPct) {
      process.stderr.write(`\rDownloading... ${pct}%`);
      lastPct = pct;
    }
  }
  await writer.end();
  if (lastPct >= 0) process.stderr.write("\n");
}

type Version = [number, number, number];

/// null for anything not x.y.z. An unorderable version on either side skips
/// the comparison entirely and installs the published release, same as
/// --force: not knowing which is newer is no reason to refuse the thing the
/// user just asked for.
function parse(version: string): Version | null {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version.trim());
  if (!match) return null;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

function compare(a: Version, b: Version): number {
  for (let i = 0; i < 3; i++) {
    if (a[i]! !== b[i]!) return a[i]! - b[i]!;
  }
  return 0;
}

export const command: Command = {
  usage: "[--force]",
  description: "Update the CLI to the latest release",
  multiArgHandler: update,
};
