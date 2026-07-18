# GitLab CI Integration

Phantom can serve as a [GitLab custom executor](https://docs.gitlab.com/runner/executors/custom.html), running each CI job inside an ephemeral macOS VM. The VM is cloned from a base template, used for the job, then deleted.

Phantom manages GitLab Runner for you: the daemon downloads the `gitlab-runner` binary, registers it against your GitLab instance, and supervises the runner process. No Homebrew install or `config.toml` editing needed.

## How It Works

```
GitLab Runner          phantom daemon         VM
(managed by daemon)          │                 │
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
2. **A base image** with `phantom-agent` installed (see [create-image.md](../create-image.md))

## Setup

1. In GitLab, create a runner (**Settings → CI/CD → Runners → New project runner**) and copy the `glrt-...` token.

2. Run:

```bash
phantom gitlab-runner setup --token glrt-xxx
```

Options:

| Flag | Description |
|------|-------------|
| `--token <token>` | Runner authentication token (required) |
| `--url <url>` | GitLab instance URL (default: `https://gitlab.com`) |
| `--concurrent <n>` | Max concurrent jobs (default: 1) |

That's it. The daemon downloads `gitlab-runner` (pinned version, stored under `~/Library/Application Support/phantom/gitlab-runner/<version>/`), registers it, and starts it. The runner restarts automatically whenever the daemon launches.

3. Point your jobs at a phantom image with the `image:` keyword (job-level or `default:`), using a local image name from `phantom image list`:

```yaml
build:
  image: tahoe-base
  tags: [phantom]
  script:
    - xcodebuild ...
```

Jobs without an `image:` fail with a clear error — the runner itself has no image configuration.

> **Note**: Each job creates a fresh VM by decompressing the image, which takes a few minutes. This is slower than a VM clone but guarantees a clean, reproducible environment from a pinned image.

### Managing the runner

```bash
phantom gitlab-runner status   # state, version, config path
phantom gitlab-runner stop     # stop the runner process
phantom gitlab-runner start    # start it again
```

Re-running `setup` replaces the previous registration (e.g. to change the base image or point at a different GitLab instance).

## Job Execution User

Job scripts run inside the VM as the `admin` user — macOS CI tooling (Homebrew, xcodebuild, simulators) misbehaves as root. Set a `PHANTOM_EXEC_USER` CI variable to override (`root` runs the script unwrapped as the agent's root user).

## How CI Variables Are Passed

GitLab Runner passes CI variables to the executor as `CUSTOM_ENV_<NAME>` environment variables. Phantom strips the prefix and injects them as `export` statements at the top of each job script before executing it in the VM. The job's `image:` keyword arrives the same way (`CI_JOB_IMAGE`) and selects the phantom image to boot.

This means all standard CI variables (`CI_COMMIT_SHA`, `CI_PROJECT_NAME`, etc.) are available inside the VM just as they would be in any other executor.

## Concurrent Jobs

Each job gets its own VM. Concurrent jobs are supported — pass `--concurrent <n>` to setup.

Each job's script is base64-encoded and piped directly into the VM over vsock, so there are no shared files and no risk of collisions between concurrent jobs.

## Under the Hood

Setup generates `~/Library/Application Support/phantom/gitlab-runner/config.toml` with a `[runners.custom]` section that points `prepare_exec`/`run_exec`/`cleanup_exec` at the phantom CLI (`phantom gitlab-runner prepare|run|cleanup`). The daemon runs `gitlab-runner run --config <that file>` as a supervised child process — your `~/.gitlab-runner/` (if any) is never touched.

## Troubleshooting

**`Registration failed`**
The token is invalid or expired. Create a new runner in GitLab and re-run setup with the fresh `glrt-...` token.

**`Runner exited unexpectedly` in `phantom gitlab-runner status`**
Check the daemon logs (runner output is forwarded with a `[gitlab-runner]` prefix), then `phantom gitlab-runner start`.

**`VM create failed` / `Start failed`**
Check that the phantom daemon is running and the image name is correct (`phantom image list`).

**`Agent unavailable`**
The template VM must have `phantom-agent` installed and configured to start on boot. See [create-image.md](../create-image.md) for installation steps.

**Jobs hang during script execution**
Check that the phantom agent is running inside the VM (`phantom vm exec <vmId> -- launchctl list com.monk.phantom-agent`). The agent must be installed and started on boot in the template VM.
