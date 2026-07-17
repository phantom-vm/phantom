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
- [ ] **6. Orchestration** — `phantom image build <name>`: ipsw pull → vm.create → boot script → provision → vm.stop → image.save, with progress reporting throughout
- [ ] **7. Base image** — build and publish the base image (agent only) to a registry so users only ever `image pull`

Known risks: `_VZVNCServer` is a private API (tart has shipped it for years); Setup Assistant screens differ across macOS versions, so boot scripts are per-version; keystroke timing needs generous waits.

### Image Compression Performance — HIGH PRIORITY

`image save` / `image create --from-image` are unacceptably slow: chunking and
reconstruction in [OCIDiskLayerizer.swift](phantom/Libs/OCI/OCIDiskLayerizer.swift)
process 512MB LZ4 chunks **one at a time on a single thread** (`for i in 0..<totalChunks`),
so a ~21GB image takes many minutes while most CPU cores sit idle. Creating a VM
from an image even exceeded the CLI's 600s request timeout.

- [ ] **Parallelize chunk compress/decompress** across cores (e.g. `DispatchQueue.concurrentPerform` or a `TaskGroup`) — the single biggest win, disk image chunks are independent.
- [ ] **Don't store all-zero chunks** — skip them at chunk time (reconstruction already skips writing zeros to keep the disk sparse), avoiding both compression and storage of empty regions.
- [ ] **Stream instead of buffering whole 512MB chunks** in memory to cut allocation pressure and allow smaller, more parallelizable units.
- [ ] **Make `vm.create --from-image` async** (fire-and-forget + status polling) like `image.save`, so long reconstructions don't hit the CLI request timeout.

### GitLab Runner

- [ ] **Registry-backed base image** — `PHANTOM_BASE_IMAGE` currently only supports local image names. Add auto-pull from a registry reference (e.g. `registry.gitlab.com/org/macos-ci:latest`) before `vm.create`, including polling `image.status` until the pull completes.
