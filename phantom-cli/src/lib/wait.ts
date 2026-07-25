import { sendRequest, type VM } from "./api";

// Waiting for a VM to come up is the same job for every caller — `vm deploy`,
// `image build`, and the GitLab executor's prepare step all start something the
// daemon runs in the background and then watch `vm.list` for it. The states that
// get watched are `installing(N%)` (from an IPSW) and `restoring(N%)` (from an
// image); both end at `running` or at an `error: …`.

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export interface WaitOptions {
  /** Give up after this long. */
  maxMs?: number;
  /** Gap between polls. Long installs deserve a longer one — the progress
   *  string changes constantly, and every change is a line of output. */
  pollMs?: number;
  /** Called once per distinct state string, for progress output. */
  onState?: (state: string) => void;
}

/**
 * Polls `vm.list` until `vmId` is running.
 *
 * Throws if the VM lands in an error state, disappears, or outlives `maxMs` —
 * in none of which cases is the VM cleaned up here, since the caller decides
 * whether a failed VM is worth keeping around to look at.
 */
export async function waitForVMRunning(vmId: string, opts: WaitOptions = {}): Promise<void> {
  const { maxMs = 45 * 60_000, pollMs = 3_000, onState } = opts;
  const deadline = Date.now() + maxMs;
  let lastState = "";

  while (Date.now() < deadline) {
    const res = await sendRequest({ method: "vm.list" });
    if (res.error) throw new Error(`vm.list: ${res.error.message}`);

    const vm = ((res.result?.vms as VM[]) ?? []).find((v) => v.id === vmId);
    if (!vm) throw new Error(`VM ${vmId} disappeared`);

    if (vm.state !== lastState) {
      onState?.(vm.state);
      lastState = vm.state;
    }
    if (vm.state === "running") return;
    if (vm.state.startsWith("error")) throw new Error(vm.state);

    await sleep(pollMs);
  }

  throw new Error(`timed out waiting for VM ${vmId} (last state: ${lastState || "unknown"})`);
}
