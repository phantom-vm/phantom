import { sendRequest, sendStreamingRequest } from "../lib/api";
import { unlinkSync } from "node:fs";
import { basename } from "node:path";
import { homedir } from "node:os";

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
  const createResp = await sendRequest(
    {
      method: "vm.create",
      params: { fromImage: baseImage },
    },
    { timeoutMs: 1800_000 } // 30 min — image decompression can take several minutes
  );
  if (createResp.error) {
    console.error(`[phantom] VM create failed: ${createResp.error.message}`);
    process.exit(SYSTEM_FAILURE);
  }
  const vmId = createResp.result?.vmId as string;

  // 2. Start VM
  console.error(`[phantom] Starting ${vmId}...`);
  const startResp = await sendRequest(
    { method: "vm.start", params: { vmId } },
    { timeoutMs: 120_000 }
  );
  if (startResp.error) {
    console.error(`[phantom] Start failed: ${startResp.error.message}`);
    await sendRequest({ method: "vm.delete", params: { vmId } });
    process.exit(SYSTEM_FAILURE);
  }

  // 3. Wait for agent to be ready
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

  // 4. Persist VM ID for run/cleanup steps
  await Bun.write(stateFilePath(jobId), vmId);
  console.error(`[phantom] VM ${vmId} ready`);
}

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

  // Job scripts run as the admin user by default — macOS CI tooling (brew,
  // xcodebuild, simulators) misbehaves as root. Override with a
  // PHANTOM_EXEC_USER CI variable; "root" skips the user wrap entirely.
  const execUser = process.env.CUSTOM_ENV_PHANTOM_EXEC_USER ?? "admin";

  // Execute in VM with streaming output
  let exitCode = BUILD_FAILURE;
  const result = await sendStreamingRequest(
    {
      method: "vm.execStream",
      params: { vmId, command, ...(execUser !== "root" && { user: execUser }) },
    },
    (chunk) => {
      if (chunk.type === "stdout" && chunk.data) process.stdout.write(chunk.data);
      if (chunk.type === "stderr" && chunk.data) process.stderr.write(chunk.data);
    }
  );
  exitCode = result.exitCode;

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
    console.error("Usage: phantom gitlab-runner setup --token <glrt-...> [--url <gitlab-url>] [--concurrent <n>]");
    console.error("\nOptions:");
    console.error("  --token <token>      Runner authentication token (create under Settings → CI/CD → Runners)");
    console.error("  --url <url>          GitLab instance URL (default: https://gitlab.com)");
    console.error("  --concurrent <n>     Max concurrent jobs (default: 1)");
    console.error("\nJobs choose their VM image with the 'image:' keyword (phantom image list).");
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

export async function gitlabRunner(...args: string[]) {
  const subcommand = args[0];

  if (subcommand === "prepare") {
    await prepare();
  } else if (subcommand === "run") {
    const scriptPath = args[1];
    if (!scriptPath) {
      console.error("Usage: phantom gitlab-runner run <script> <stage>");
      process.exit(SYSTEM_FAILURE);
    }
    await run(scriptPath);
  } else if (subcommand === "cleanup") {
    await cleanup();
  } else if (subcommand === "setup") {
    await setup(args.slice(1));
  } else if (subcommand === "status") {
    await daemonCommand("gitlab.status");
  } else if (subcommand === "start") {
    await daemonCommand("gitlab.start");
  } else if (subcommand === "stop") {
    await daemonCommand("gitlab.stop");
  } else {
    console.error(`Unknown subcommand: ${subcommand ?? "(none)"}`);
    console.error("Usage: phantom gitlab-runner <setup|status|start|stop|prepare|run|cleanup>");
    process.exit(1);
  }
}
