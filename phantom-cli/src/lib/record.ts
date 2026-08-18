// The build record: what an image says about how it was made.
//
// A recipe is the intent, written before the build; this is the account of what
// actually happened, written into the image at save time and carried by push
// and pull as a layer of its own. Between them, an image that lands on someone
// else's Mac can answer "which Xcode, which runner, from which base, by which
// scripts" without booting it.
//
// The daemon stores it verbatim and only reads the handful of fields it
// advertises in the manifest's annotations, so a richer record is a CLI change
// alone.

import { createHash } from "node:crypto";
import { VERSION } from "../version";
import { call } from "./guest";

export interface RecordedStep {
  name: string;
  /// Path of the script that ran, as the recipe named it.
  script?: string;
  /// SHA-256 of that script's bytes — the version of it that ran, which a path
  /// alone does not pin.
  sha256?: string;
  /// An inline command, for a step that was one.
  run?: string;
  env?: Record<string, string>;
  /// Who it ran as. admin unless the step asked for root.
  user: string;
  /// How it reached the guest: vsock for a command, vnc for the Setup
  /// Assistant keystroke script, which has no exit code to report.
  via: "vsock" | "vnc";
  exitCode?: number;
  durationSec: number;
}

export interface BuildRecord {
  schemaVersion: 1;
  name: string;
  description?: string;
  builtAt: string;
  builtBy: string;
  daemon?: string;
  host?: { macOS?: string; build?: string };
  /// What this image was made from: a base image (layered builds) or an IPSW
  /// (base builds).
  from: {
    image?: string;
    /// The registry digest of that base, when it is knowable — it is recorded
    /// by a pull. A base built on this Mac has never been named by a registry,
    /// so this is absent and `manifestSha256` is what identifies it locally.
    digest?: string;
    manifestSha256?: string;
    ipsw?: string;
  };
  recipe?: { path: string; sha256: string; source: string };
  steps: RecordedStep[];
}

export const sha256 = (data: string | Uint8Array) =>
  "sha256:" + createHash("sha256").update(data).digest("hex");

export async function sha256File(path: string): Promise<string> {
  return sha256(new Uint8Array(await Bun.file(path).arrayBuffer()));
}

/// Times a step and returns what to record about it. The work throws on
/// failure, and a failed build saves no image — so a recorded step is a step
/// that succeeded, and `exitCode` is there for a reader who should not have to
/// know that.
export async function recordStep<T>(
  step: Omit<RecordedStep, "durationSec" | "exitCode">,
  work: () => Promise<T>
): Promise<{ result: T; recorded: RecordedStep }> {
  const started = Date.now();
  const result = await work();
  return {
    result,
    recorded: { ...step, exitCode: 0, durationSec: Math.round((Date.now() - started) / 1000) },
  };
}

/// The facts about this machine and these tools, asked for once per build.
export async function provenance(): Promise<Pick<BuildRecord, "builtBy" | "daemon" | "host">> {
  let daemon: string | undefined;
  try {
    daemon = (await call("health")).version as string;
  } catch {
    // A build that got this far has a daemon; if health is unreadable the
    // record is worth writing without it.
  }

  const sw = Bun.spawnSync(["sw_vers"]).stdout.toString();
  const field = (name: string) => sw.match(new RegExp(`^${name}:\\s*(.+)$`, "m"))?.[1]?.trim();

  return {
    builtBy: `phantom-cli ${VERSION}`,
    daemon,
    host: { macOS: field("ProductVersion"), build: field("BuildVersion") },
  };
}

/// What a locally held image can say about its own identity, for the `from`
/// field of whatever is layered onto it.
export async function baseIdentity(name: string): Promise<BuildRecord["from"]> {
  const res = await call("image.list");
  const images = (res.images ?? []) as {
    name: string;
    pulledFrom?: { digest: string };
  }[];
  const found = images.find((i) => i.name === name);
  return { image: name, digest: found?.pulledFrom?.digest };
}
