# GitLab CI Integration

Phantom can serve as a [GitLab custom executor](https://docs.gitlab.com/runner/executors/custom.html), running each CI job inside an ephemeral macOS VM. The VM is restored from a pinned local image, used for the job, then deleted.

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
2. **An image with `phantom-agent` installed** — pull a published one, which is
   the usual case:

   ```bash
   phantom image catalog
   phantom image pull xcode-26-6
   ```

   Authoring your own instead is covered in [authoring-images.md](../authoring-images.md).

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
| `--concurrent <n>` | Max concurrent jobs, 1 or 2 (default: 1) |

Two is the ceiling on concurrency because Virtualization.framework runs at most two macOS VMs at a time, and every job is a VM.

That's it. The daemon downloads `gitlab-runner` (pinned version, stored under `~/Library/Application Support/phantom/gitlab-runner/<version>/`), registers it, and starts it. The runner restarts automatically whenever the daemon launches.

Everything above — the URL, the token, concurrency, and how big each job's VM is — can also be seen and changed later in the app, under **Integration › GitLab Runner › Configure…**. Job VMs are created with 4 CPUs and 16GB by default; `phantom gitlab-runner status` reports the current size. Changing it takes effect on the next job, without restarting the runner.

3. Point your jobs at a phantom image with the `image:` keyword (job-level or `default:`), using a local image name from `phantom image list`:

```yaml
test:
  image: xcode-26-6
  tags: [phantom]
  script:
    - xcodebuild test -scheme MyApp -destination 'platform=macOS'
```

The image must already be pulled on the host — a job's `image:` names a **local**
image and does not trigger a pull.

Jobs without an `image:` fail with a clear error — the runner itself has no image configuration.

### Artifacts and cache

`artifacts:` and `cache:` work with no per-project setup:

```yaml
test:
  image: xcode-26-6
  tags: [phantom]
  script:
    - xcodebuild test -scheme MyApp -destination 'platform=macOS' -resultBundlePath test-results/macos.xcresult
  artifacts:
    paths:
      - test-results/
```

The custom executor runs a job's upload stages *inside* the VM, so they need
`gitlab-runner` there. Layered builds bake it in; a base image does not, since
plenty of VMs are never used for CI at all. Naming one in a job's `image:` is
therefore fine right up until the job wants an artifact — at which point the
runner skips the stage and **the job still passes**, with the artifact simply
never arriving.

Prepare warns rather than letting that happen quietly:

```
[phantom] WARNING: 'tahoe-base' has no gitlab-runner in the guest.
[phantom] WARNING: artifacts and cache stages will be skipped and this job
[phantom] WARNING: will still report success. Please use an image built with
[phantom] WARNING: gitlab-runner installed if this job needs them.
```

The fix is to build the image with the binary in it — layer it
(`phantom image build <name> --image <name> --replace`) or pass
`--gitlab-runner` to a base build — rather than curling the binary in a
`before_script`. A job that needs no artifacts or cache can ignore the warning.

> **Note**: Each job creates a fresh VM by decompressing the image, which takes a few minutes. That cost buys a clean, reproducible environment from a pinned image on every run.

### Managing the runner

```bash
phantom gitlab-runner status   # state, version, config path
phantom gitlab-runner stop     # stop the runner process
phantom gitlab-runner start    # start it again
```

Re-running `setup` replaces the previous registration (e.g. to change the base image or point at a different GitLab instance).

## Cancelling a Job

Pressing **Cancel** stops the job's script inside the VM, and the stages GitLab
runs afterwards — `after_script`, uploading artifacts for the now-failed job —
go ahead normally in a VM that is still healthy. `cleanup_exec` then deletes it.
Measured end to end, a cancel is over in **under twenty seconds**, most of that
the artifact stage doing its job.

Nothing in the executor needs to do anything clever for this. The cancel arrives
as a `SIGTERM` on the stage that is running and the CLI dies on it in about
90ms; the daemon notices the client has hung up, drops the exec, and the guest
agent takes that as its cue to stop the script and every process under it.

**This needs an image whose agent is v1.6.0 or newer** — the catalog images
published on 2026-07-31 and anything built since. Against an older image nothing
stops the abandoned script, and because the agent there serves one command at a
time, the stages after the cancel queue behind a build nobody wants: a measured
cancel took **4m41s**, all of it waiting for an `xcodebuild` that had already
been cancelled. `phantom image pull <name>` refreshes a stale copy.

Whether a cancelled job uploads artifacts depends on when it was cancelled, not
on the cancel: the stage runs either way and uploads whatever the job had
produced by then. A job cancelled mid-compile has nothing to show; one cancelled
after its tests wrote their results uploads them as usual.

A cancel during the restore is handled by the same path — `prepare` records the
VM before the restore begins, so `cleanup_exec` deletes it rather than leaving
it to finish booting with no job to serve.

## Job Execution User

Job scripts run inside the VM as the `admin` user — macOS CI tooling (Homebrew, xcodebuild, simulators) misbehaves as root. Set a `PHANTOM_EXEC_USER` CI variable to override (`root` runs the script unwrapped as the agent's root user).

## How CI Variables Are Passed

GitLab Runner passes CI variables to the executor as `CUSTOM_ENV_<NAME>` environment variables. Phantom strips the prefix and injects them as `export` statements at the top of each job script before executing it in the VM. The job's `image:` keyword arrives the same way (`CI_JOB_IMAGE`) and selects the phantom image to boot.

This means all standard CI variables (`CI_COMMIT_SHA`, `CI_PROJECT_NAME`, etc.) are available inside the VM just as they would be in any other executor.

## Concurrent Jobs

Each job gets its own VM. Concurrent jobs are supported — pass `--concurrent <n>` to setup, up to two: that is how many macOS VMs Virtualization.framework will run at once, so a third job would only wait for a slot.

Each job's script is base64-encoded and piped directly into the VM over vsock, so there are no shared files and no risk of collisions between concurrent jobs.

Two concurrent jobs means two VMs of the size configured under **Integration › GitLab Runner › Configure…** running on one Mac, so the two settings are worth choosing together.

## Under the Hood

Setup generates `~/Library/Application Support/phantom/gitlab-runner/config.toml` with a `[runners.custom]` section that points `prepare_exec`/`run_exec`/`cleanup_exec` at the phantom CLI (`phantom gitlab-runner prepare|run|cleanup`). The daemon runs `gitlab-runner run --config <that file>` as a supervised child process — your `~/.gitlab-runner/` (if any) is never touched.

The job VM's size is not in that file: it is nothing gitlab-runner knows about, and registering rewrites `config.toml` from scratch. It lives beside it in `job-vm.json`, and `prepare` asks the daemon for it when it creates the job's VM.

## Troubleshooting

**`Registration failed`**
The token is invalid or expired. Create a new runner in GitLab and re-run setup with the fresh `glrt-...` token.

**`Runner exited unexpectedly` in `phantom gitlab-runner status`**
Check the daemon logs (runner output is forwarded with a `[gitlab-runner]` prefix), then `phantom gitlab-runner start`.

**`VM create failed` / `Start failed`**
Check that the phantom daemon is running and the image name is correct (`phantom image list`).

**`Agent unavailable`**
The image must have `phantom-agent` installed and starting on boot, which every published image does. See [authoring-images.md](../authoring-images.md) if you built the image yourself.

**Jobs hang during script execution**
Check that the phantom agent is running inside the VM (`phantom vm exec <vmId> -- launchctl list com.monk.phantom-agent`). The agent must be installed and started on boot in the image the job names.
