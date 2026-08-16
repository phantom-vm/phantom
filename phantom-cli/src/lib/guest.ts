// The pieces both builders share: talking to the daemon, running something
// inside the guest, handing the guest a local file, and waiting out a save.
//
// `image build-base` (IPSW → base image) and `image build` (recipe → layered
// image) are deliberately separate commands with separate flows; what they have
// in common is not the pipeline but these primitives.

import { sendRequest } from "./api";

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/// A daemon call that throws instead of returning an error object — every
/// caller here would otherwise have to unwrap it the same way.
export async function call(method: string, params?: Record<string, any>, timeoutMs = 30_000) {
  const res = await sendRequest({ method, params }, { timeoutMs });
  if (res.error) throw new Error(`${method}: ${res.error.message}`);
  return res.result;
}

/// Shell-quotes a value for the `KEY='value'` lines prepended to a command.
const quote = (value: string) => `'${value.replace(/'/g, "'\\''")}'`;

export interface GuestRun {
  vmId: string;
  /// What to run: a script's whole text, or a one-line command.
  body: string;
  /// Prepended as assignments rather than passed as arguments, because
  /// vm.exec appends its args to the command string — which for a multi-line
  /// script body lands them on the last line instead of on the script.
  env?: Record<string, string>;
  timeoutMs: number;
  /// Names the step in an error, so a failed build says which one failed.
  label: string;
}

/// Runs one thing in the guest over vsock, echoing its output as it comes back.
export async function runInGuest({ vmId, body, env, timeoutMs, label }: GuestRun) {
  const assignments = Object.entries(env ?? {})
    .map(([key, value]) => `${key}=${quote(value)}`)
    .join("\n");
  const command = assignments ? `${assignments}\n${body}` : body;

  const res = await call("vm.exec", { vmId, command, waitForAgent: true }, timeoutMs);
  const log = (res.stdout as string) ?? "";
  for (const line of log.split("\n").filter((l) => l.trim())) console.log(`    ${line}`);

  // The exit code is the whole verdict. Every script here runs under `set -e`,
  // so a failure anywhere in it lands as a non-zero status, and a step that
  // wants to assert something beyond "the script ran" is a step that greps for
  // it — an assertion belongs in a command, not in a key of the recipe format.
  if (res.exitCode !== 0) {
    throw new Error(`${label} exited ${res.exitCode}: ${res.stderr ?? ""}`);
  }
  return log;
}

/// Serves one local file to the guest over an ephemeral HTTP server bound to
/// the host side of the NAT network, so a 10GB archive needs neither a copy nor
/// a shared folder. Lives only as long as the step that asked for it.
export function serveFile(path: string): { url: string; stop: () => void } {
  const hostIP = natBridgeAddress();
  const name = path.split("/").pop()!;
  const server = Bun.serve({
    hostname: hostIP,
    port: 0,
    // Only this file is served, whatever the path — nothing else on the host is
    // reachable through it.
    fetch: () => new Response(Bun.file(path)),
  });
  return {
    url: `http://${hostIP}:${server.port}/${encodeURIComponent(name)}`,
    stop: () => server.stop(true),
  };
}

/// The vmnet NAT network's host-side address — a NAT guest reaches the host
/// there. The bridge interface only exists while a NAT VM is running, which it
/// is by the time any step runs.
function natBridgeAddress(): string {
  const proc = Bun.spawnSync(["ifconfig"]);
  const blocks = proc.stdout.toString().split(/^(?=\S)/m);
  for (const block of blocks) {
    if (block.startsWith("bridge")) {
      const m = block.match(/inet (\d+\.\d+\.\d+\.\d+)/);
      if (m) return m[1]!;
    }
  }
  throw new Error(
    "cannot find the vmnet bridge address (is the VM running?) — serve a URL the guest can reach instead"
  );
}

/// Flush the guest's disk cache, then stop. `vm.stop` is a force stop
/// (VZVirtualMachine.stop() is "like unplugging the machine"), so anything
/// still in the guest's buffer cache — the whole build, potentially — would be
/// missing from the saved image without this.
export async function flushAndStop(vmId: string) {
  await call("vm.exec", { vmId, command: "sync; sync; sync", waitForAgent: true }, 60_000);
  await sleep(3_000);
  await call("vm.stop", { vmId }, 60_000);
}

/// Waits out image.save, which is fire-and-forget on the daemon side.
///
/// This tracks image.status rather than watching for the name to turn up in
/// image.list: with --replace the name is there the whole time (that is the
/// point — the old image stays usable until the new one is complete), so a
/// list-based wait returns immediately and the VM gets deleted out from under
/// the save that is still reading its disk.
///
/// A save is only over once the state leaves `saving`, so wait for that state to
/// appear first — a stale `completed` from an earlier operation would otherwise
/// end the wait before the save had begun. Chunking a real VM disk takes minutes,
/// so the window cannot be missed at this poll interval.
export async function waitForSave(name: string, maxMs = 60 * 60_000) {
  const deadline = Date.now() + maxMs;
  let started = false;
  let lastMsg = "";
  while (Date.now() < deadline) {
    const { state, message } = (await call("image.status")) as {
      state: string;
      message?: string;
    };
    if (state === "saving") {
      started = true;
      if (message && message !== lastMsg) {
        console.log(`    ${message}`);
        lastMsg = message;
      }
    } else if (started) {
      if (state === "completed") return;
      // Includes `cancelled`: someone ran `phantom image cancel` on the save
      // this build was waiting for, which ends the build rather than leaving it
      // watching a state that will never come.
      throw new Error(`image save ${state === "cancelled" ? "cancelled" : `failed (${state})`}: ${message ?? ""}`);
    }
    await sleep(3_000);
  }
  throw new Error(`image save of '${name}' timed out`);
}
