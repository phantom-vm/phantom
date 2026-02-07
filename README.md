# Phantom

A macOS app that manages macOS virtual machines using Apple's Virtualization.framework.

## Architecture

Two parts:
* **Daemon app** (this repo) — SwiftUI macOS app that exposes a JSON API over TCP for VM lifecycle management
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

### Phase 1.5: Host-to-Guest Command Execution PoC (done)
Establish a vsock + JSON channel to execute commands inside the VM from the host.

**Host side (this app):**
- [x] Add `VZVirtioSocketDeviceConfiguration` to VM config
- [x] Connect to guest agent on vsock port 9001
- [x] Send JSON command `{"command": "...", "args": [...]}`
- [x] Receive JSON response `{"stdout": "...", "stderr": "...", "exitCode": 0}`
- [x] Add "Run Command" UI to test it
- [x] Shared directory via `VZVirtioFileSystemDeviceConfiguration` for file transfer

**Guest agent (runs inside the VM):**
- [x] Small Swift CLI tool that listens on vsock port 9001
- [x] Reads JSON commands, executes via `Process`, returns JSON output
- [x] Build as standalone binary, manually install into VM
- [x] Set up as launchd agent for auto-start (see [phantom-agent/README.md](phantom-agent/README.md))
  - Note: Host-side setup script could be moved to phantom CLI in the future

### Phase 2: TCP JSON API (Network.framework) (done)
Zero-dependency TCP server on localhost using Apple's Network.framework. Newline-delimited JSON protocol.

- [x] Create `TCPServer` using `NWListener` on `localhost:9090`
- [x] Define JSON-RPC-style request/response protocol:
  - Request: `{"method": "images.list"}` / `{"method": "vms.create", "params": {"imageId": "..."}}`
  - Response: `{"result": {...}}` / `{"error": "..."}`
- [x] Implement handlers: `health`, `images.list`, `images.pull`, `vms.list`, `vms.create`, `vms.stop`
- [x] Start server on app launch alongside VM manager

### Phase 3: CLI Tool (Bun)
- [ ] Scaffold Bun project at `./phantom-cli`
- [ ] TCP client using `Bun.connect()` to `localhost:9090`
- [ ] Implement CLI commands that send JSON requests and print results

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`
