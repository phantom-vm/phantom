# Phantom

A macOS app that manages macOS virtual machines using Apple's Virtualization.framework.

## Architecture

Two parts:
* **Daemon app** (this repo) — SwiftUI macOS app that exposes a JSON REST API for VM lifecycle management
* **CLI tool** (`../phantom-cli`) — Bun-based CLI that calls the daemon's API

## MVP CLI Commands

* `phantom image pull` — pull macOS restore image (IPSW) from Apple
* `phantom image list` — show available images
* `phantom ps` — show running VMs
* `phantom run IMAGE` — start a new VM from image
* `phantom stop VM_ID` — stop a macOS VM

## Progress

### Phase 1: Core VM Demo (done)
- [x] Download macOS restore image (IPSW) from Apple with progress
- [x] Create VM bundle (disk image, aux storage, machine identifier, hardware model)
- [x] Install macOS into VM via `VZMacOSInstaller`
- [x] Start/stop VM with `VZVirtualMachine`
- [x] VM display window via `VZVirtualMachineView`
- [x] Persist VM bundles across app restarts (start existing VM without reinstall)
- [x] Delete VM (stop + remove bundle)

### Phase 2: HTTP REST API (next)
- [ ] Add FlyingFox HTTP server dependency
- [ ] Expose API on `http://localhost:9090`
- [ ] `GET /health` — health check
- [ ] `GET /images` — list downloaded images
- [ ] `POST /images/pull` — download latest image
- [ ] `GET /vms` — list running VMs
- [ ] `POST /vms` — create & start VM
- [ ] `DELETE /vms/:id` — stop VM

### Phase 3: CLI Tool
- [ ] Scaffold Bun project at `../phantom-cli`
- [ ] Implement CLI commands that call the REST API

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- FlyingFox (lightweight async HTTP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`
