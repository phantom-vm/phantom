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
- [ ] **3. Boot-command engine** — Swift VNC client in the daemon + keystroke DSL (`<wait10s>`, `<tab>`, `<spacebar>`, literal text) + `<click 'text'>` using Vision.framework OCR on the framebuffer to locate and click on-screen text. New API: `vm.bootScript`
- [ ] **4. Setup Assistant script** — port tart's `vanilla-sequoia` boot_command sequence (create local admin account, skip Apple ID, set timezone, disable VoiceOver); end by opening Terminal in the guest and typing the phantom-agent install one-liner (`mount_virtiofs` + `install.sh`), handing control off to the vsock agent
- [ ] **5. Provisioning via agent** — passwordless sudo, auto-login (`/etc/kcpassword`), disable sleep/screensaver/screen lock, optional Gatekeeper off — all through `vm.exec`
- [ ] **6. Orchestration** — `phantom image build <name>`: ipsw pull → vm.create → boot script → provision → vm.stop → image.save, with progress reporting throughout
- [ ] **7. Base image** — build and publish the base image (agent only) to a registry so users only ever `image pull`

Known risks: `_VZVNCServer` is a private API (tart has shipped it for years); Setup Assistant screens differ across macOS versions, so boot scripts are per-version; keystroke timing needs generous waits.

### GitLab Runner

- [ ] **Registry-backed base image** — `PHANTOM_BASE_IMAGE` currently only supports local image names. Add auto-pull from a registry reference (e.g. `registry.gitlab.com/org/macos-ci:latest`) before `vm.create`, including polling `image.status` until the pull completes.
