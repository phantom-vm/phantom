import { sendRequest, sendStreamingRequest } from "../lib/api";
import { unlinkSync } from "node:fs";

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
  const baseVm = process.env.CUSTOM_ENV_PHANTOM_BASE_VM;
  if (!baseVm) {
    console.error("[phantom] Error: CUSTOM_ENV_PHANTOM_BASE_VM not set");
    process.exit(SYSTEM_FAILURE);
  }

  // 1. Clone base VM
  console.error(`[phantom] Cloning ${baseVm} for job ${jobId}...`);
  const createResp = await sendRequest({
    method: "vm.create",
    params: { sourceVmId: baseVm },
  });
  if (createResp.error) {
    console.error(`[phantom] Clone failed: ${createResp.error.message}`);
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

  // Execute in VM with streaming output
  let exitCode = BUILD_FAILURE;
  const result = await sendStreamingRequest(
    { method: "vm.execStream", params: { vmId, command } },
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
  } else {
    console.error(`Unknown subcommand: ${subcommand ?? "(none)"}`);
    console.error("Usage: phantom gitlab-runner <prepare|run|cleanup>");
    process.exit(1);
  }
}
