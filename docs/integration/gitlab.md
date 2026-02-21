# GitLab CI Integration

Phantom can serve as a [GitLab custom executor](https://docs.gitlab.com/runner/executors/custom.html), running each CI job inside an ephemeral macOS VM. The VM is cloned from a base template, used for the job, then deleted.

## How It Works

```
GitLab Runner          phantom daemon         VM
      │                      │                 │
      │  prepare              │                 │
      ├─────────────────────▶│ Create VM from  │
      │                      │ image           │
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

Each CI job gets a fresh VM created from a local image, guaranteeing a clean and reproducible environment.

## Prerequisites

1. **Phantom daemon running** on the host Mac
2. **GitLab Runner installed** on the same Mac (`brew install gitlab-runner`)
3. **A base image** with `phantom-agent` installed (see [create-image.md](../create-image.md))

## Setup

### 1. Prepare a base image

Build a VM with `phantom-agent` installed, save it as a local image, and optionally push it to a registry for reuse across machines:

```bash
phantom image list
# NAME                 SIZE
# macos-sequoia-base   42.3 GB   ← use this as your base image
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
    PHANTOM_BASE_IMAGE = "macos-sequoia-base"
```

Replace `macos-sequoia-base` with your local image name (`phantom image list`).

> **Note**: Each job creates a fresh VM by decompressing the image, which takes a few minutes. This is slower than a VM clone but guarantees a clean, reproducible environment from a pinned image.

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

**`CUSTOM_ENV_PHANTOM_BASE_IMAGE not set`**
Add `PHANTOM_BASE_IMAGE` to `[runners.env]` in `config.toml`.

**`VM create failed` / `Start failed`**
Check that the phantom daemon is running and the image name is correct (`phantom image list`).

**`Agent unavailable`**
The template VM must have `phantom-agent` installed and configured to start on boot. See [create-image.md](../create-image.md) for installation steps.

**Jobs hang during script execution**
Check that the phantom agent is running inside the VM (`phantom vm exec <vmId> -- launchctl list com.monk.phantom-agent`). The agent must be installed and started on boot in the template VM.
