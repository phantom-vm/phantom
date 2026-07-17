# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Documentation

- [Create a Ready-to-Use Phantom Image](docs/create-image.md) — set up a base VM with phantom-agent installed and save it as an image
- [GitLab CI Integration](docs/integration/gitlab.md) — use Phantom as a GitLab custom executor for ephemeral macOS CI jobs

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

### Automated Image Building

Goal: `phantom image build <name>` — one command from IPSW to a ready-to-use image with phantom-agent installed, zero manual interaction. Approach follows tart's proven pipeline (VNC keystroke injection + OCR clicks), adapted to phantom's daemon architecture: once the agent is installed via VNC-typed commands, all remaining provisioning goes through `vm.exec` over vsock — no SSH required.

- [x] **1. Headless install** — verify `vm.create` installs macOS from IPSW without GUI interaction; support `ipsw pull latest` via `VZMacOSRestoreImage.fetchLatestSupported()` *(already the case: `VZMacOSInstaller` runs headless, `ipsw.pull` uses `VZMacOSRestoreImage.latestSupported`)*
- [x] **2. VNC server in daemon** — start `_VZVNCServer` (private API, invoked via reflection) for a running VM; it works during installation and Setup Assistant with no guest-side software. New API: `vm.vnc.start` / `vm.vnc.stop` → `vnc://:password@127.0.0.1:port`; CLI: `phantom vm vnc <vm-id> [--stop]`
- [x] **3. Boot-command engine** — Swift VNC client in the daemon + keystroke DSL (`<wait10s>`, `<tab>`, `<spacebar>`, literal text) + `<click 'text'>` using Vision.framework OCR on the framebuffer to locate and click on-screen text. New API: `vm.bootScript` / `vm.bootScript.status`; CLI: `phantom vm boot-script <vm-id> --file <script>`. Verified end-to-end against a live VM (keystroke injection + OCR click both confirmed).
- [x] **4. Setup Assistant script** — [provision/setup-tahoe.txt](provision/setup-tahoe.txt) drives macOS Tahoe Setup Assistant (create local admin `phantom`/`phantom`, skip Apple ID, agree to terms), reaches the desktop, opens Terminal, and installs the agent (`mount_virtiofs` + `install.sh`), handing control off to the vsock agent. Verified end-to-end on a live macOS 26.3 install. Added `vm.screenshot` to author scripts against live screens, plus two boot-engine fixes surfaced by real Setup Assistant screens: exact-match OCR (so `<click 'Agree'>` avoids "Disagree") and explicit Shift for uppercase/symbol keystrokes.
- [x] **5. Provisioning via agent** — [provision/provision.sh](provision/provision.sh): passwordless sudo, auto-login (`/etc/kcpassword`), disable sleep/screensaver/screen lock — all through `vm.exec` over vsock. Verified applied on a live VM.
- [x] **6. Orchestration** — `phantom image build <name>` ([phantom-cli/src/commands/build.ts](phantom-cli/src/commands/build.ts)): resolve IPSW → stage agent → `vm.create` (async, poll install) → boot script (Setup Assistant) → provision over vsock → `vm.stop` → `image.save` → delete the intermediate VM, with step-by-step progress. **Verified: one unattended command builds a ready-to-use base image.** Two daemon fixes were needed for reliable unattended runs: `vm.create --from-ipsw` returns the vmId immediately and installs in the background; and after install the installer's VM instance is torn down and a fresh one booted (the installer's own instance flakily hangs on a black screen instead of reaching Setup Assistant).
- [ ] **7. Publish base image** — push the built base image to a registry so users only ever `image pull` (build pipeline is done; publishing/`push` wiring remains)

Known risks: `_VZVNCServer` is a private API (tart has shipped it for years); Setup Assistant screens differ across macOS versions, so boot scripts are per-version; keystroke timing needs generous waits.

### Image Compression Performance

The real cause of the original slowness was not a lack of concurrency but
actor isolation: [OCIDiskLayerizer.swift](phantom/Libs/OCI/OCIDiskLayerizer.swift)
inherited the project's default `MainActor` isolation, so every `compress` /
`decompress` / `isAllZeros` call hopped back to the main thread and ran
serially — even inside a `TaskGroup`.

- [x] **Parallelize chunk compress/decompress** — marked the layerizer (and `Digest`) `nonisolated` so the work runs off-main, made `chunkDisk` async with a `TaskGroup` (per-chunk `pread`, concurrency = min(cores, 6)), and pointed reconstruction at the same cap. **Save (24GB VM) went from minutes to ~16s.**
- [x] **Fix `isAllZeros`** — was the real bottleneck for create-from-image: a hand-rolled Swift loop over 512 MB per chunk that, in the unoptimized dev build, cost ~2600s of CPU (per-phase timing pinned it exactly). Replaced with libc `memcmp` (`buf[0]==0 && memcmp(buf, buf+1, n-1)==0`), which is vectorized regardless of build mode. **Create-from-image went from 460s to ~12s** (zeroCheck 2595s → 1.2s); verified the resulting VM boots and its agent responds. Writes (~30GB) run at >1GB/s and were never the problem.
- [ ] **Don't store all-zero chunks** — skip them at chunk time (reconstruction already skips writing zeros to keep the disk sparse), avoiding compression and storage of empty regions.
- [ ] **Make `vm.create --from-image` async** (fire-and-forget + status polling) like `image.save`; also fixes the bug where a CLI timeout leaves the bundle on disk unregistered until the next daemon restart. Less urgent now that create is ~12s.

### GitLab Runner

- [ ] **Registry-backed base image** — `PHANTOM_BASE_IMAGE` currently only supports local image names. Add auto-pull from a registry reference (e.g. `registry.gitlab.com/org/macos-ci:latest`) before `vm.create`, including polling `image.status` until the pull completes.
