import { sendRequest, sendStreamingRequest } from "../lib/api";
import { waitForVMRunning } from "../lib/wait";
import { unlinkSync } from "node:fs";
import { basename } from "node:path";
import { homedir } from "node:os";
import { usageError, type Command } from "../command";

// One record for both the router and `phantom help`, like every other group.
// (These used to be pseudo-subcommands: the group took its whole arg vector and
// dispatched internally, which cost it its own "Unknown subcommand" line and
// kept the executor hooks fused into a single undispatchable help row.)
export const commands: Record<string, Command> = {
  setup: {
    usage: "--token <glrt-...> [options]",
    description: "Register + start a managed runner (one-time)",
    details: [
      "--token <token>   Runner authentication token (create under Settings → CI/CD → Runners)",
      "--url <url>       GitLab instance URL (default: https://gitlab.com)",
      "--concurrent <n>  Max concurrent jobs (default: 1)",
      "",
      "Jobs choose their VM image with the 'image:' keyword (phantom image list).",
    ],
    multiArgHandler: (...args: string[]) => setup(args),
  },
  status: { usage: "", description: "Show runner state", handler: () => daemonCommand("gitlab.status") },
  start: {
    usage: "",
    description: "Start the runner (also happens automatically on daemon launch)",
    handler: () => daemonCommand("gitlab.start"),
  },
  stop: { usage: "", description: "Stop the runner", handler: () => daemonCommand("gitlab.stop") },
  prepare: {
    usage: "",
    description: "Executor hook: create the job's VM (invoked by gitlab-runner itself)",
    handler: () => prepare(),
  },
  run: {
    usage: "<script> <stage>",
    description: "Executor hook: run one job step in the VM",
    handler: (scriptPath?: string) => {
      if (!scriptPath) {
        console.error("Usage: phantom gitlab-runner run <script> <stage>");
        process.exit(SYSTEM_FAILURE);
      }
      return run(scriptPath);
    },
  },
  cleanup: {
    usage: "",
    description: "Executor hook: delete the job's VM",
    handler: () => cleanup(),
  },
};

// GitLab custom executor exit codes (set by runner as env vars)
const SYSTEM_FAILURE = parseInt(process.env.SYSTEM_FAILURE_EXIT_CODE ?? "1");
const BUILD_FAILURE = parseInt(process.env.BUILD_FAILURE_EXIT_CODE ?? "1");

function getJobId(): string {
  const jobId = process.env.CUSTOM_ENV_CI_JOB_ID;
  if (!jobId) {
    console.error("[phantom] Error: CUSTOM_ENV_CI_JOB_ID not set");
    process.exit(SYSTEM_FAILURE);
  }
  return jobId;
}

function stateFilePath(jobId: string): string {
  return `/tmp/phantom-gitlab-runner-${jobId}`;
}

/// Who the job's commands run as. Job scripts run as the admin user by default
/// — macOS CI tooling (brew, xcodebuild, simulators) misbehaves as root.
/// Override with a PHANTOM_EXEC_USER CI variable; "root" skips the user wrap
/// entirely, since a bare exec is already root.
function execUser(): string {
  return process.env.CUSTOM_ENV_PHANTOM_EXEC_USER ?? "admin";
}

async function prepare() {
  const jobId = getJobId();
  // The image comes from the job's `image:` keyword (default: or job-level)
  const baseImage = process.env.CUSTOM_ENV_CI_JOB_IMAGE;
  if (!baseImage) {
    console.error("[phantom] Error: no image specified — set 'image: <name>' in the job (phantom image list)");
    process.exit(SYSTEM_FAILURE);
  }

  // 1. Create VM from image
  console.error(`[phantom] Creating VM from image ${baseImage} for job ${jobId}...`);
  const createResp = await sendRequest({
    method: "vm.create",
    params: { fromImage: baseImage },
  });
  if (createResp.error) {
    console.error(`[phantom] VM create failed: ${createResp.error.message}`);
    process.exit(SYSTEM_FAILURE);
  }
  const vmId = createResp.result?.vmId as string;

  // 2. Claim the VM before the restore rather than after it. A cancel during
  // those minutes leaves cleanup something to delete; otherwise the daemon
  // finishes restoring, boots the VM, and it stays up with no job left to serve.
  await Bun.write(stateFilePath(jobId), vmId);

  // 3. Wait out the restore, which the daemon runs in the background and
  // finishes by booting the VM. Decompressing a 90GB disk takes minutes, so the
  // states are echoed into the job log — a silent prepare looks like a hang.
  console.error(`[phantom] Restoring ${vmId}...`);
  try {
    await waitForVMRunning(vmId, {
      maxMs: 60 * 60_000,
      onState: (state) => console.error(`[phantom] ${vmId}: ${state}`),
    });
  } catch (err) {
    console.error(`[phantom] VM never came up: ${err instanceof Error ? err.message : err}`);
    await sendRequest({ method: "vm.delete", params: { vmId } });
    process.exit(SYSTEM_FAILURE);
  }

  // 4. Wait for agent to be ready
  console.error(`[phantom] Waiting for agent...`);
  const agentResp = await sendRequest(
    { method: "vm.exec", params: { vmId, command: "echo ready", waitForAgent: true } },
    { timeoutMs: 120_000 }
  );
  if (agentResp.error) {
    console.error(`[phantom] Agent unavailable: ${agentResp.error.message}`);
    await sendRequest({ method: "vm.delete", params: { vmId } });
    process.exit(SYSTEM_FAILURE);
  }

  // 5. Say so if the guest cannot upload artifacts or touch the cache
  await warnIfNoGitLabRunner(vmId, baseImage);

  console.error(`[phantom] VM ${vmId} ready`);
}

/// GitLab runs the artifact and cache stages inside the guest too, by shelling
/// out to `gitlab-runner artifacts-uploader` / `cache-archiver`. With no such
/// binary the runner skips those stages and the job still passes — the artifact
/// simply never arrives. Only layered builds bake it in, so a job that names a
/// base image hits this, and nothing in the job log explains it.
///
/// A warning rather than a failure: a lean image is a legitimate choice for a
/// job that only runs a script, and the defect here is the silence, not the
/// missing binary.
async function warnIfNoGitLabRunner(vmId: string, image: string) {
  // Probed exactly the way the job resolves it. GitLab runs the uploader
  // through the same run_exec path as the script, so the user wrap has to
  // match: a bare exec is root with PATH /usr/bin:/bin:/usr/sbin:/sbin, which
  // cannot see /usr/local/bin and would warn about every image.
  const user = execUser();
  const resp = await sendRequest({
    method: "vm.exec",
    params: {
      vmId,
      command: "command -v gitlab-runner",
      ...(user !== "root" && { user }),
    },
  });

  // A probe that could not run tells us nothing about the image, so it stays
  // quiet rather than guessing.
  if (resp.error || resp.result?.exitCode == null) return;
  if (resp.result.exitCode === 0) return;

  console.error(`[phantom] WARNING: '${image}' has no gitlab-runner in the guest.`);
  console.error(`[phantom] WARNING: artifacts and cache stages will be skipped and this job`);
  console.error(`[phantom] WARNING: will still report success. Please use an image built with`);
  console.error(`[phantom] WARNING: gitlab-runner installed if this job needs them.`);
}

/// A cancel reaches the custom executor as a SIGTERM on the stage that is
/// running, and this process dies on it in about 90ms. That is all it has to
/// do: the daemon notices the client hanging up, drops the exec, and the guest
/// agent stops the job's script and everything under it. GitLab then runs the
/// stages that follow a cancelled script — after_script, uploading artifacts
/// for the now-failed job — in a VM that is still healthy, and `cleanup_exec`
/// deletes it.
///
/// This needs the agent from v1.6.0 or later in the guest. Against an older
/// image the command runs on with nobody listening, and those stages queue
/// behind it: the four-minute cancel this was all about.
async function run(scriptPath: string) {
  const jobId = getJobId();

  let vmId: string;
  try {
    vmId = (await Bun.file(stateFilePath(jobId)).text()).trim();
  } catch {
    console.error(`[phantom] State file not found for job ${jobId}`);
    process.exit(SYSTEM_FAILURE);
  }

  // Collect CI env vars (CUSTOM_ENV_* → strip prefix → export statements)
  const envExports = Object.entries(process.env)
    .filter(([key]) => key.startsWith("CUSTOM_ENV_"))
    .map(([key, value]) => {
      const name = key.slice("CUSTOM_ENV_".length);
      const escaped = (value ?? "").replace(/'/g, "'\\''");
      return `export ${name}='${escaped}'`;
    })
    .join("\n");

  // Prepend env exports to the GitLab-generated script, then base64-encode
  // and pipe into the VM — no temp files or shared dir needed
  const originalScript = await Bun.file(scriptPath).text();
  const fullScript = envExports + "\n" + originalScript;
  const base64 = Buffer.from(fullScript).toString("base64");
  const command = `printf '%s' '${base64}' | base64 -d | sh`;

  const user = execUser();

  // Execute in VM with streaming output
  let exitCode = BUILD_FAILURE;
  try {
    const result = await sendStreamingRequest(
      {
        method: "vm.execStream",
        params: { vmId, command, ...(user !== "root" && { user }) },
      },
      (chunk) => {
        if (chunk.type === "stdout" && chunk.data) process.stdout.write(chunk.data);
        if (chunk.type === "stderr" && chunk.data) process.stderr.write(chunk.data);
      }
    );
    exitCode = result.exitCode;
  } catch (err) {
    console.error(`[phantom] Exec failed: ${err instanceof Error ? err.message : err}`);
    exitCode = SYSTEM_FAILURE;
  }

  process.exit(exitCode);
}

async function cleanup() {
  const jobId = getJobId();
  const stateFile = stateFilePath(jobId);

  let vmId: string;
  try {
    vmId = (await Bun.file(stateFile).text()).trim();
  } catch {
    // Prepare may have failed before writing state — nothing to clean up
    return;
  }

  console.error(`[phantom] Deleting VM ${vmId}...`);
  await sendRequest({ method: "vm.delete", params: { vmId } });
  try { unlinkSync(stateFile); } catch {}
  console.error(`[phantom] Cleanup complete`);
}

// The daemon's runner config invokes this CLI as the custom executor, so it
// needs an absolute path to the binary. In dev mode (`bun run src/main.ts`)
// execPath points at bun itself — fall back to the installed binary.
function cliBinaryPath(): string {
  if (basename(process.execPath) !== "bun") return process.execPath;
  return `${homedir()}/.local/bin/phantom`;
}

async function setup(args: string[]) {
  let url = "https://gitlab.com";
  let token: string | undefined;
  let concurrent: number | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--url" && i + 1 < args.length) url = args[++i]!;
    else if (args[i] === "--token" && i + 1 < args.length) token = args[++i];
    else if (args[i] === "--concurrent" && i + 1 < args.length) concurrent = parseInt(args[++i]!);
  }

  if (!token) {
    console.error("Error: --token is required");
    console.error("");
    usageError("gitlab-runner", "setup", commands.setup!);
    process.exit(1);
  }

  console.log("Setting up GitLab runner (downloads gitlab-runner on first run, may take a minute)...");
  const resp = await sendRequest(
    {
      method: "gitlab.setup",
      params: { url, token, cliPath: cliBinaryPath(), concurrent },
    },
    { timeoutMs: 600_000 } // binary download + registration
  );
  if (resp.error) {
    console.error(`Setup failed: ${resp.error.message}`);
    process.exit(1);
  }
  printStatus(resp.result);
  console.log("\nRunner is ready — CI jobs will now run in ephemeral phantom VMs.");
}

function printStatus(result: any) {
  console.log(`State:      ${result?.state}`);
  console.log(`Version:    ${result?.version}`);
  console.log(`Configured: ${result?.configured}`);
  console.log(`Running:    ${result?.running}`);
  if (result?.configPath) console.log(`Config:     ${result.configPath}`);
}

async function daemonCommand(method: string) {
  const resp = await sendRequest({ method }, { timeoutMs: 600_000 });
  if (resp.error) {
    console.error(`Error: ${resp.error.message}`);
    process.exit(1);
  }
  printStatus(resp.result);
}
