# GitLab CI Integration

Phantom can serve as a [GitLab custom executor](https://docs.gitlab.com/runner/executors/custom.html), running each CI job inside an ephemeral macOS VM. The VM is cloned from a base template, used for the job, then deleted.

## How It Works

```
GitLab Runner          phantom daemon         VM
      │                      │                 │
      │  prepare              │                 │
      ├─────────────────────▶│ Clone base VM   │
      │                      │ Start VM        │
      │                      │ Wait for agent  │
      │                      ├────────────────▶│
      │                      │                 │
      │  run (build step)     │                 │
      ├─────────────────────▶│ Inline script   │
      │                      │ (base64-encoded)│
      │  streaming output     │ Execute script  │
      │◀─────────────────────│◀────────────────│
      │                      │                 │
      │  cleanup              │                 │
      ├─────────────────────▶│ Delete VM       │
      │                      │                 │
```

Each CI job gets a fresh VM cloned from your template via APFS copy-on-write — fast and storage-efficient.

## Prerequisites

1. **Phantom daemon running** on the host Mac
2. **GitLab Runner installed** on the same Mac (`brew install gitlab-runner`)
3. **A template VM** with `phantom-agent` installed (see [manual.md](../manual.md))

## Setup

### 1. Prepare a template VM

Create and configure a base VM that will be cloned for each CI job. It must have `phantom-agent` installed and running so Phantom can execute commands inside it.

Note the VM ID — you'll need it in step 3.

```bash
phantom list
# VM ID                STATE
# vm-abc123            stopped   ← use this as your template
```

### 2. Register a GitLab Runner

```bash
gitlab-runner register \
  --url https://gitlab.com \
  --token <your-runner-token> \
  --name "phantom-macos" \
  --executor custom
```

### 3. Configure the runner

Edit `~/.gitlab-runner/config.toml` and add the custom executor config to your runner section:

```toml
[[runners]]
  name = "phantom-macos"
  url = "https://gitlab.com"
  token = "<your-runner-token>"
  executor = "custom"

  [runners.custom]
    prepare_exec      = "phantom"
    prepare_exec_args = ["gitlab-runner", "prepare"]
    run_exec          = "phantom"
    run_exec_args     = ["gitlab-runner", "run"]
    cleanup_exec      = "phantom"
    cleanup_exec_args = ["gitlab-runner", "cleanup"]

  [runners.env]
    PHANTOM_BASE_VM = "vm-abc123"
```

Replace `vm-abc123` with your template VM's ID.

### 4. Start the runner

```bash
gitlab-runner run
```

## How CI Variables Are Passed

GitLab Runner passes CI variables to the executor as `CUSTOM_ENV_<NAME>` environment variables. Phantom strips the prefix and injects them as `export` statements at the top of each job script before executing it in the VM.

This means all standard CI variables (`CI_COMMIT_SHA`, `CI_PROJECT_NAME`, etc.) are available inside the VM just as they would be in any other executor.

## Concurrent Jobs

Each job gets its own VM. Concurrent jobs are supported — configure `concurrent` in `config.toml`:

```toml
concurrent = 4
```

Each job's script is base64-encoded and piped directly into the VM over vsock, so there are no shared files and no risk of collisions between concurrent jobs.

## Troubleshooting

**`CUSTOM_ENV_PHANTOM_BASE_VM not set`**
Add `PHANTOM_BASE_VM` to `[runners.env]` in `config.toml`.

**`Clone failed` / `Start failed`**
Check that the phantom daemon is running and the template VM ID is correct (`phantom list`).

**`Agent unavailable`**
The template VM must have `phantom-agent` installed and configured to start on boot. See [manual.md](../manual.md) for installation steps.

**Jobs hang during script execution**
Check that the phantom agent is running inside the VM (`phantom vm exec <vmId> -- launchctl list com.monk.phantom-agent`). The agent must be installed and started on boot in the template VM.
