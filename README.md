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

### Phase 1.5: Host-to-Guest Command Execution PoC (next)
Establish a vsock + JSON channel to execute commands inside the VM from the host.

**Host side (this app):**
- [ ] Add `VZVirtioSocketDeviceConfiguration` to VM config
- [ ] Connect to guest agent on vsock port 9001
- [ ] Send JSON command `{"command": "...", "args": [...]}`
- [ ] Receive JSON response `{"stdout": "...", "stderr": "...", "exitCode": 0}`
- [ ] Add "Run Command" UI to test it

**Guest agent (runs inside the VM):**
- [ ] Small Swift CLI tool that listens on vsock port 9001
- [ ] Reads JSON commands, executes via `Process`, returns JSON output
- [ ] Build as standalone binary, manually install into VM
- [ ] Set up as launchd agent for auto-start

### Phase 2: TCP JSON API (Network.framework)
Zero-dependency TCP server on localhost using Apple's Network.framework. Newline-delimited JSON protocol.

- [ ] Create `TCPServer` using `NWListener` on `localhost:9090`
- [ ] Define JSON-RPC-style request/response protocol:
  - Request: `{"method": "images.list"}` / `{"method": "vms.create", "params": {"imageId": "..."}}`
  - Response: `{"result": {...}}` / `{"error": "..."}`
- [ ] Implement handlers: `health`, `images.list`, `images.pull`, `vms.list`, `vms.create`, `vms.stop`
- [ ] Start server on app launch alongside VM manager

### Phase 3: CLI Tool (Bun)
- [ ] Scaffold Bun project at `../phantom-cli`
- [ ] TCP client using `Bun.connect()` to `localhost:9090`
- [ ] Implement CLI commands that send JSON requests and print results

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`
