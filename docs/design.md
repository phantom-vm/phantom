# Phantom Design Document

A macOS VM manager built on Apple's Virtualization.framework with a TCP API and CLI interface.

## System Overview

Phantom consists of three interconnected components:

```
┌─────────────────────────────────────────────────────────┐
│                    Host System (macOS)                   │
│                                                           │
│  ┌──────────────┐         ┌─────────────────┐           │
│  │  phantom-cli │────────▶│  phantom daemon │           │
│  │   (Bun CLI)  │  TCP    │   (Swift app)   │           │
│  └──────────────┘  :9090  │                 │           │
│                            │  • GUI (SwiftUI)│           │
│                            │  • TCP Server   │           │
│                            │  • VM Manager   │           │
│                            └────────┬────────┘           │
│                                     │ vsock :9001        │
│                                     ▼                     │
│                     ┌──────────────────────────┐         │
│                     │    macOS Virtual Machine │         │
│                     │                          │         │
│                     │  ┌────────────────────┐  │         │
│                     │  │  phantom-agent     │  │         │
│                     │  │  (launchd daemon)  │  │         │
│                     │  └────────────────────┘  │         │
│                     └──────────────────────────┘         │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### Components

1. **phantom daemon** - SwiftUI app that manages VMs and exposes a TCP API
2. **phantom-cli** - Bun-based CLI tool for controlling VMs
3. **phantom-agent** - Runs inside VMs to execute commands from the host

---

## Architecture

### Daemon (Swift App)

The daemon is a standard macOS SwiftUI application with three main subsystems:

**File Structure**:
```
phantom/
├── phantomApp.swift      # App entry point, initializes TCPServer
├── ContentView.swift     # SwiftUI GUI
├── APIHandlers.swift     # API request routing
├── APIModels.swift       # JSON protocol definitions
└── Libs/
    ├── VMManager.swift   # VM lifecycle management
    ├── IPSWManager.swift # IPSW download and listing
    ├── GitLabRunnerManager.swift # Managed GitLab Runner (download, register, supervise)
    ├── TCPServer.swift   # Network.framework TCP server
    ├── VNCServer.swift   # Host-side VNC server (_VZVNCServer private API)
    ├── Provision/
    │   ├── RFBClient.swift        # Minimal RFB 3.8 client (keys, pointer, framebuffer)
    │   ├── BootCommand.swift      # Keystroke DSL parser (<wait>, <tab>, <click '...'>)
    │   └── BootScriptRunner.swift # Executes boot commands, OCR clicks via Vision
    └── OCI/
        ├── OCITypes.swift          # Manifest, descriptor, media types, digest
        ├── OCIReference.swift      # Registry reference parsing
        ├── OCIAuth.swift           # Bearer/Basic auth + Docker config
        ├── OCIRegistry.swift       # OCI Distribution API HTTP client
        ├── OCIDiskLayerizer.swift  # Disk chunking + LZ4 compression
        └── OCIImageManager.swift   # Image CRUD + push/pull orchestration
```

**State Management**:
- Uses `@Observable` macro for reactive state
- All state mutations happen on `@MainActor`
- `IPSWManager` owns IPSW download state, referenced by `VMManager.ipswManager`
- `OCIImageManager` owns image operations state, referenced by `VMManager.imageManager`
- `VMManager` tracks multiple VMs via `vmInstances` dictionary
- Observable properties: `ipswManager.state`, `vmInstances`, `logs`, etc.

**Initialization Flow**:
1. App launches → `phantomApp.body` renders
2. `.task {}` modifier creates `TCPServer(vmManager: vm)`
3. Server starts listening on localhost:9090
4. GUI displays current VM state

### CLI (Bun/TypeScript)

Single-file CLI that sends JSON-RPC requests to the daemon.

**Two build flavors, two entry points**: `src/main-admin.ts` (`bun run install-bin`) includes the image-authoring commands (`ipsw`, `image build`, `vm boot-script`); `src/main.ts` (`bun run build-user-bin`) simply never imports `commands/ipsw.ts` or the admin-only exports from `commands/vm.ts`/`commands/image.ts`, so that code is absent from the compiled binary via plain unused-module elimination — regular users start from a published base image. (An earlier version of this gated commands behind a `--define`d runtime flag instead; that doesn't reliably dead-code-eliminate once a module is more than a couple of functions, so it was replaced with this static-import-graph split.) Each `commands/*.ts` module exports `Command` records — usage/description bundled with the handler at one declaration site — that both the router and `phantom help` read directly (see `command.ts`, `cli.ts`). This is CLI UX/binary-size only: the daemon API keeps all endpoints regardless of which CLI build talks to it.

**File**: `phantom-cli/src/main.ts` (260 lines)

**Command Flow**:
1. Parse command-line arguments
2. Construct JSON request: `{"method": "vm.list"}`
3. Connect to localhost:9090 via `Bun.connect()`
4. Send request with newline delimiter
5. Read response until newline
6. Parse JSON and display formatted output

### Guest Agent (Swift)

Lightweight vsock server that executes commands inside the VM.

**File**: `phantom-agent/Sources/main.swift` (180 lines)

**Startup**:
- Installed as launchd daemon at `/Library/LaunchDaemons/com.monk.phantom-agent.plist`
- Starts automatically on VM boot with `RunAtLoad` and `KeepAlive`
- Binds to vsock port 9001

**Request Handling**:
1. Accept connection from host
2. Read newline-delimited JSON: `{"command": "whoami", "args": null}`
3. Execute via `/bin/sh -c`
4. Capture stdout, stderr, exit code
5. Send newline-delimited JSON response
6. Keep connection open for more commands

---

## Data Flow

### VM Lifecycle

**Creating a New VM**:

```
CLI                     Daemon                  VM
 │                         │                    │
 │  vm.create            │                    │
 ├────────────────────────▶│                    │
 │                         │                    │
 │                         │ Load IPSW          │
 │                         │ Create disk image  │
 │                         │ Generate hardware  │
 │                         │ Start installer    │
 │                         │                    │
 │  {"status":"started"}   │                    │
 │◀────────────────────────┤                    │
 │                         │                    │
 │  (poll vm.list)        │  Installing...     │
 │────────────────────────▶│────────────────────▶│
 │                         │                    │
 │  {"state":"running"}    │                    │
 │◀────────────────────────┤                    │
```

**Listing VMs**:

```
CLI                     Daemon                  Filesystem
 │                         │                    │
 │  vm.list              │                    │
 ├────────────────────────▶│                    │
 │                         │                    │
 │                         │ Scan vms/          │
 │                         ├───────────────────▶│
 │                         │                    │
 │                         │ [vm-abc, vm-def]   │
 │                         │◀───────────────────┤
 │                         │                    │
 │                         │ Check states       │
 │                         │                    │
 │  [{"id":"vm-abc",       │                    │
 │    "state":"running"}]  │                    │
 │◀────────────────────────┤                    │
```

### Command Execution in VM

```
Daemon                    Guest Agent           Shell
  │                          │                    │
  │  Connect vsock :9001     │                    │
  ├─────────────────────────▶│                    │
  │                          │                    │
  │  {"command":"ls -la"}    │                    │
  ├─────────────────────────▶│                    │
  │                          │                    │
  │                          │  /bin/sh -c "ls"   │
  │                          ├───────────────────▶│
  │                          │                    │
  │                          │  stdout, stderr    │
  │                          │◀───────────────────┤
  │                          │                    │
  │  {"stdout":"...",        │                    │
  │   "exitCode":0}          │                    │
  │◀─────────────────────────┤                    │
  │                          │                    │
  │  Close connection        │                    │
  ├─────────────────────────▶│                    │
```

### API Request Lifecycle

```
┌──────────────────────────────────────────────────────────┐
│ 1. Client Connection                                      │
│    - CLI connects to localhost:9090                       │
│    - NWListener accepts connection                        │
│    - Connection handler registered                        │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│ 2. Request Reception                                      │
│    - NWConnection.receive() reads data                    │
│    - Buffer until newline found                           │
│    - Extract JSON request                                 │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│ 3. Processing (on MainActor)                              │
│    - Parse JSON: {"method":"vm.list"}                    │
│    - Route to APIHandlers.handleVmsList()                 │
│    - Call VMManager.listVMs()                             │
│    - Scan filesystem for VM bundles                       │
│    - Build response: {"result":{"vms":[...]}}             │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│ 4. Response Transmission                                  │
│    - Serialize response to JSON                           │
│    - Append newline delimiter                             │
│    - NWConnection.send()                                  │
│    - Close connection                                     │
└──────────────────────────────────────────────────────────┘
```

---

## Storage Layout

```
~/Library/Application Support/phantom/
│
├── ipsws/                    # Downloaded IPSW files
│   ├── 25C56.ipsw            # macOS restore image (14-18GB)
│   └── 24C61.ipsw
│
├── vms/                      # VM bundles
│   ├── vm-abc123/
│   │   ├── disk.img          # 90GB sparse disk image
│   │   ├── AuxiliaryStorage  # Binary blob
│   │   ├── MachineIdentifier # Binary blob
│   │   └── HardwareModel     # Binary blob
│   │
│   └── vm-def456/
│       └── ...
│
├── images/                   # Local OCI images
│   ├── macos-base/
│   │   ├── manifest.json     # OCI manifest (layers + digests)
│   │   ├── config.json       # VM config (HardwareModel as base64)
│   │   ├── nvram.bin         # AuxiliaryStorage
│   │   ├── pulled.json       # Pulled images only: reference, digest, date
│   │   └── disk/             # LZ4-compressed disk chunks (zero chunks absent)
│   │       ├── 000.lz4
│   │       ├── 002.lz4
│   │       └── ...
│   └── macos-dev/
│       └── ...
│
├── shared/                   # Mounted in all VMs
│   ├── phantom-agent         # Guest agent binary
│   ├── install.sh            # Installation script
│   ├── uninstall.sh
│   └── com.monk.phantom-agent.plist
│
└── gitlab-runner/            # Managed GitLab Runner
    ├── v18.11.2/
    │   └── gitlab-runner     # Versioned binary downloaded from GitLab S3
    ├── config.toml           # Runner config owned by phantom (never touches ~/.gitlab-runner)
    └── template.toml         # Register template pointing the custom executor at phantom-cli
```

**VM Bundle Contents**:
- `disk.img` - Created via `ftruncate()`, 90GB sparse file
- `AuxiliaryStorage` - VM-specific data, persisted across boots
- `MachineIdentifier` - Unique VM identity
- `HardwareModel` - CPU/hardware configuration

**Shared Directory**:
- Exposed to VMs via VirtioFS with tag "phantom-shared"
- Mounted in guest: `mount_virtiofs phantom-shared /Volumes/phantom-shared`
- Used for transferring phantom-agent to VMs


---

## Communication Protocols

### TCP API Protocol (Daemon ↔ CLI)

**Transport**: TCP on localhost:9090
**Format**: Newline-delimited JSON
**Pattern**: One request per connection (stateless)

**Request Structure**:
```json
{
  "method": "vm.create",
  "params": {
    "ipswId": "25C56"
  }
}
```

**Response Structure**:
```json
{
  "result": {
    "status": "started",
    "message": "VM creation started"
  }
}
```

Or on error:
```json
{
  "error": {
    "code": "ipsw_not_found",
    "message": "IPSW not found: 25C56"
  }
}
```

### vsock Protocol (Daemon ↔ Guest)

**Transport**: vsock on port 9001
**Format**: Newline-delimited JSON
**Pattern**: Multiple commands per connection

**Batch Request**:
```json
{"command": "ls", "args": ["-la", "/tmp"]}
```

**Batch Response**:
```json
{"stdout": "total 0\ndrwx... .\n", "stderr": "", "exitCode": 0}
```

**Streaming Request** (when `stream: true`):
```json
{"command": "xcodebuild ...", "stream": true}
```

**Streaming Response** (multiple lines):
```
{"type":"stdout","data":"Building for debugging...\n"}
{"type":"stderr","data":"warning: ...\n"}
{"type":"exit","exitCode":0}
```

---

## API Endpoints

### health
- **Purpose**: Check daemon status
- **Response**: `{"status": "ok", "version": "1.0.0"}`

### ipsw.list
- **Purpose**: List downloaded IPSW files
- **Implementation**: Scans `~/Library/Application Support/phantom/ipsws/`
- **Response**: `{"ipsws": [{"id": "25C56", "path": "...", "size": 17000000000}]}`

### ipsw.pull
- **Params**: `url` (string, optional), `build` (string, optional — required with `url`)
- **Purpose**: Download macOS restore IPSW
- **Implementation**:
  - Without params: fetches `VZMacOSRestoreImage.latestSupported` (Apple's API)
  - With `url`+`build`: downloads a specific build to `<build>.ipsw`. The URL comes from the CLI's catalog (VirtualBuddy's curated `data/ipsws_v2.json`, an auditable public git repo), so the daemon pins it: https, host `updates.cdn-apple.com`, filename `UniversalMac_*_Restore.ipsw` — any other URL is refused. Restore image signatures are additionally verified by Virtualization.framework at install time.
  - Downloads via URLSession with progress tracking, returns immediately (async operation)
- **Response**: `{"status": "started", "message": "IPSW download started"}`

### ipsw.status
- **Purpose**: Poll current IPSW download state
- **Response**: `{"state": "none|fetching|downloading|downloaded|error", "progress": 0.5, "message": "..."}`

### vm.list
- **Purpose**: List all VM bundles
- **Implementation**: Scans `~/Library/Application Support/phantom/vms/`
- **Response**: `{"vms": [{"id": "vm-abc", "path": "...", "state": "running"}]}`

### vm.create
- **Params**: Exactly one of `ipswId` (string), `sourceVmId` (string), or `fromImage` (string)
- **Purpose**: Create a new VM from an IPSW, by cloning an existing VM, or from a saved OCI image
- **Implementation**:
  - `ipswId`: Validates IPSW exists, then returns a generated `vmId` immediately and runs the ~20-minute install in a background task. Poll `vm.list` for the VM's state (`creating` → `installing(N%)` → `running`). After the install finishes, the installer's VM instance is torn down and a **fresh** `VZVirtualMachine` is booted from the bundle — the installer's own instance flakily hangs on a black screen instead of reaching Setup Assistant; a clean restart is reliable.
  - `sourceVmId`: APFS CoW clone of existing VM bundle
  - `fromImage`: Decompresses image chunks (in parallel) into a new VM bundle, generates a fresh MachineIdentifier
- **Response**: `{"status": "started"|"success", "message": "...", "vmId": "vm-..."}`

### vm.start
- **Params**: `vmId` (string)
- **Purpose**: Start an existing stopped VM
- **Implementation**: Loads VM bundle, builds config with VirtioFS shared directory, calls `VZVirtualMachine.start()`
- **Response**: `{"status": "running", "vmId": "vm-abc"}`

### vm.stop
- **Params**: `vmId` (string)
- **Purpose**: Stop running VM
- **Implementation**: Calls `VZVirtualMachine.stop()`
- **Response**: `{"status": "stopped", "vmId": "vm-abc"}`

### vm.exec
- **Params**: `vmId` (string), `command` (string), `args` (string[], optional), `user` (string, optional), `waitForAgent` (bool, optional)
- **Purpose**: Execute command inside running VM via vsock
- **Implementation**: Connects to guest agent on vsock port 9001. When `waitForAgent` is true, retries connection every 2s for up to 120s (for freshly booted VMs). The agent runs as root; when `user` is set, the daemon wraps the command in `su - <user> -c '…'` so it runs as that user with their login environment (no agent change needed). With an auto-logged-in user this even reaches the GUI session — e.g. `--user admin -- open -a Notes` opens Notes on the desktop.
- **Response**: `{"stdout": "...", "stderr": "...", "exitCode": 0}`
- **CLI**: `phantom vm exec <vm-id> [--user <name>] -- <command>`

### vm.execStream
- **Params**: `vmId` (string), `command` (string), `args` (string[], optional), `user` (string, optional), `waitForAgent` (bool, optional)
- **Purpose**: Execute command with streaming output. Connection stays open, sending chunks as they arrive.
- **Protocol**: Newline-delimited JSON chunks:
  - `{"type":"stdout","data":"..."}`
  - `{"type":"stderr","data":"..."}`
  - `{"type":"done","exitCode":0}` (final chunk, connection closes)

### vm.display
- **Params**: `vmId` (string)
- **Purpose**: Open VM display window in the daemon GUI
- **Implementation**: Sets `displayedVMId` and increments `displayRequestCounter` on VMManager. ContentView observes the counter and calls `openWindow(id: "vm-display")`.
- **Response**: `{"status": "ok", "vmId": "vm-abc"}`

### vm.vnc.start
- **Params**: `vmId` (string)
- **Purpose**: Start a VNC server for a running VM (idempotent — returns the existing server's URL if already started)
- **Implementation**: Uses Virtualization.framework's private `_VZVNCServer` API (invoked via the ObjC runtime, see `VNCServer.swift`). Serves the framebuffer directly from the host, so it works during macOS installation and Setup Assistant with no guest-side software. Random 8-char password, system-assigned port. The server is stopped automatically when the VM stops.
- **Response**: `{"status": "ok", "vmId": "vm-abc", "url": "vnc://:password@127.0.0.1:port"}`

### vm.vnc.stop
- **Params**: `vmId` (string)
- **Purpose**: Stop the VM's VNC server
- **Response**: `{"status": "stopped", "vmId": "vm-abc"}`

### vm.bootScript
- **Params**: `vmId` (string), `commands` (string[])
- **Purpose**: Drive a running VM through its VNC server by injecting keystrokes and OCR-guided clicks — used to automate the macOS Setup Assistant during image building. The DSL is validated synchronously (bad syntax fails the call); execution runs in the background.
- **DSL**: `<wait30s>` pauses, `<tab>`/`<enter>`/`<spacebar>`/`<f5>`... special keys, `<leftShiftOn>`/`<leftShiftOff>`... modifier hold/release, `<click 'Some Text'>` OCRs the framebuffer (Vision.framework) and clicks the matched text, anything else is typed literally. Note: the guest maps Alt to the Command key. Implemented in `Libs/Provision/`.
- **Implementation**: Starts (or reuses) the VM's VNC server, connects a minimal RFB 3.8 client (`RFBClient`), and runs each command via `BootScriptRunner` on a detached task. Progress is exposed through `vm.bootScript.status`.
- **Response**: `{"status": "started", "vmId": "vm-abc", "total": 42}`

### vm.bootScript.status
- **Params**: `vmId` (string)
- **Purpose**: Poll boot-script progress
- **Response**: `{"state": "idle|running|completed|error", "message": "..."}` (message present for running/error)

### vm.screenshot
- **Params**: `vmId` (string), `path` (string, optional — defaults to a temp PNG)
- **Purpose**: Capture the VM's current screen to a PNG. Starts a VNC server if needed. Primarily an aid for authoring/debugging boot scripts against a new macOS version.
- **Implementation**: Connects an `RFBClient` to the VM's VNC server and encodes one framebuffer to PNG.
- **Response**: `{"status": "ok", "vmId": "vm-abc", "path": "/.../screen.png"}`

### vm.delete
- **Params**: `vmId` (string)
- **Purpose**: Delete VM bundle from disk
- **Implementation**: Stops VM if running, removes bundle directory
- **Response**: `{"status": "deleted", "vmId": "vm-abc"}`

### image.save
- **Params**: `vmId` (string), `name` (string)
- **Purpose**: Save a stopped VM as a local OCI image
- **Implementation**: Fire-and-forget. Reads HardwareModel (base64-encoded into config JSON), copies AuxiliaryStorage as nvram.bin, chunks disk.img into 512MB LZ4-compressed layers, writes manifest.json.
- **Response**: `{"status": "started", "message": "Saving VM '...' as image '...'"}`

### image.list
- **Purpose**: List locally saved OCI images
- **Response**: `{"images": [{"name": "macos-base", "diskChunks": 5, "totalSize": 12345678, "createdAt": "2024-01-01T00:00:00Z"}]}`

### image.delete
- **Params**: `name` (string)
- **Purpose**: Delete a local image
- **Response**: `{"status": "deleted", "name": "macos-base"}`

### image.push
- **Params**: `name` (string), `reference` (string), `username` (string, optional), `password` (string, optional)
- **Purpose**: Push a local image to an OCI-compatible registry
- **Implementation**: Fire-and-forget. Checks blob existence on registry (skips if already present), uploads missing blobs, then pushes manifest with tag.
- **Response**: `{"status": "started", "message": "Pushing image '...' to ..."}`

### image.pull
- **Params**: `reference` (string), `name` (string, optional), `username` (string, optional), `password` (string, optional)
- **Purpose**: Pull an image from an OCI registry to local storage
- **Implementation**: Fire-and-forget. Fetches manifest, downloads config/nvram/disk blobs, saves to local image directory.
- **Response**: `{"status": "started", "message": "Pulling image from ..."}`

### image.status
- **Purpose**: Poll current image operation state (saving, pushing, pulling)
- **Response**: `{"state": "idle|saving|pushing|pulling|completed|error", "progress": 0.5, "message": "..."}`

### gitlab.setup
- **Params**: `url` (string), `token` (string), `cliPath` (string), `concurrent` (int, optional)
- **Purpose**: One-shot managed GitLab Runner setup
- **Implementation**: Downloads the pinned gitlab-runner binary to `gitlab-runner/<version>/` if missing (clears quarantine xattr), writes a template config pointing the custom executor at `cliPath`, runs `gitlab-runner register --non-interactive`, then starts the runner as a supervised child process. Re-running replaces the previous registration. Jobs select their VM image via the `image:` keyword (`CUSTOM_ENV_CI_JOB_IMAGE`) and run as `admin` by default (`PHANTOM_EXEC_USER` overrides).
- **Response**: gitlab.status payload

### gitlab.status
- **Purpose**: Report managed runner state
- **Response**: `{"state": "not_configured|downloading|registering|running|stopped|error: ...", "configured": bool, "running": bool, "version": "v18.11.2", "binaryDownloaded": bool, "configPath": "..."}`

### gitlab.start
- **Purpose**: Start the runner from an existing config (also happens automatically on daemon launch)
- **Response**: gitlab.status payload

### gitlab.stop
- **Purpose**: Terminate the supervised runner process
- **Response**: gitlab.status payload

---

## OCI Image Architecture

Phantom supports saving VMs as OCI-compatible images that can be pushed to and pulled from any OCI registry (Docker Hub, GHCR, etc.).

### Media Types

| Content | Media Type |
|---------|-----------|
| OCI Manifest | `application/vnd.oci.image.manifest.v1+json` |
| OCI Config | `application/vnd.oci.image.config.v1+json` |
| VM Config | `application/vnd.monk-studio.phantom.config.v1` |
| NVRAM | `application/vnd.monk-studio.phantom.nvram.v1` |
| Disk Chunk (LZ4) | `application/vnd.monk-studio.phantom.disk.v1` |

### OCI Manifest Structure

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:...",
    "size": 50
  },
  "layers": [
    { "mediaType": "...phantom.config.v1", "digest": "sha256:...", "size": 456 },
    { "mediaType": "...phantom.nvram.v1", "digest": "sha256:...", "size": 789 },
    { "mediaType": "...phantom.disk.v1", "digest": "sha256:...", "size": 1024,
      "annotations": {
        "vnd.monk-studio.phantom.uncompressed-size": "536870912",
        "vnd.monk-studio.phantom.chunk-index": "0"
      }
    }
  ]
}
```

The OCI config blob is: `{"architecture":"arm64","os":"darwin"}`

### Disk Layerization

- Disk images are split into **512MB chunks**, each LZ4-compressed
- Each chunk becomes one OCI layer with `uncompressed-size` and `chunk-index` annotations
- **All-zero chunks are not stored.** A 90GB disk holding ~25GB of data has most of its slots untouched — 114 of `tahoe-base`'s 180 chunks were all-zero — and `ftruncate` alone reproduces them on restore. Dropping them costs little space (each compressed to ~3MB) but removes ~63% of the layers, and with them that share of registry objects and push/pull round trips.
- Because chunks are missing, **a layer's position no longer implies its offset**: the offset comes from `chunk-index` (or, for local chunk files, the index encoded in the `%03d.lz4` file name). Images written before this annotation existed have every chunk present, so a missing value falls back to the layer's position and they keep restoring, pushing and pulling unchanged.
- On restore: `ftruncate` creates a sparse disk, chunks are decompressed in parallel and `pwrite`-ten at their indexed offsets. Restore also skips writing any all-zero chunk it does receive (old images), keeping the file sparse. All-zero detection uses libc `memcmp` (fast even in unoptimized builds).
- Concurrency: `OCIDiskLayerizer` is `nonisolated` so compress/decompress run off the main actor; up to `min(cores, 6)` concurrent chunks (bounds peak RAM). Chunking reads each chunk with `pread` for lock-free parallel reads.

### Image Flows

**Save (VM → Local Image)**:
1. Validate VM exists and is stopped
2. Create `images/<name>/` directory
3. Base64-encode HardwareModel into `config.json`
4. Copy AuxiliaryStorage → `nvram.bin`
5. Chunk `disk.img` → LZ4 compress → `disk/000.lz4`, `disk/002.lz4`, ... (all-zero chunks written nowhere, so the numbering has gaps)
6. Compute SHA-256 digests, write `manifest.json` with each layer's `chunk-index`

**Push (Local Image → Registry)**:
1. Read local `manifest.json`
2. For each layer: check if blob exists on registry (`HEAD`), upload if missing (`POST` + `PUT`)
3. Push manifest with tag (`PUT`)

**Pull (Registry → Local Image)**:
1. Fetch manifest from registry (`GET`), verified against the requested digest when the reference is one
2. Download all blobs (config, nvram, disk chunks) to `images/<name>/`, naming each chunk file after its layer's `chunk-index` so restore can find its offset. Disk chunks download concurrently, bounded by the same `min(cores, 6)` cap as save/restore — one connection to a registry CDN is the bottleneck, not the link: serial pulls measured ~9MB/s against ghcr where the same link pushed at ~23MB/s, and concurrency took a 58.9GB image from an estimated two hours to 41 minutes
3. Save manifest locally

**Create from Image (Local Image → VM)**:
1. Read config JSON, decode base64 HardwareModel
2. Create new VM bundle directory
3. Write HardwareModel file
4. Copy nvram.bin → AuxiliaryStorage
5. Decompress disk chunks → `pwrite` each at `chunk-index × 512MB` → `disk.img` (sparse; slots with no chunk stay holes)
6. Generate fresh MachineIdentifier
7. Register in `vmInstances`

### Automated Image Building (`image build`)

`phantom image build <name>` is a CLI-side orchestrator ([phantom-cli/src/commands/build.ts](../phantom-cli/src/commands/build.ts)) that chains existing daemon endpoints into a hands-off pipeline. All the sequencing and long-polling lives in the CLI; the daemon stays a set of primitive operations.

1. **Resolve IPSW** — `ipsw.list`; use `--ipsw` or the single downloaded IPSW
2. **Stage agent** (optional `--agent-dir`) — runs `init-host-shared-folder.sh` to build phantom-agent into the shared folder
3. **Install** — `vm.create` (returns `vmId` immediately), poll `vm.list` until `running`
4. **Setup Assistant** — `vm.bootScript` with `provision/setup-tahoe.txt`, poll `vm.bootScript.status` until `completed`; this also installs the agent inside the guest via VNC-typed Terminal commands
5. **Provision** — `vm.exec` runs `provision/provision.sh` over vsock (passwordless sudo, auto-login, no sleep)
6. **Install Xcode** (optional `--xcode <url|path>`) — see below
7. **Stop** — `vm.stop` (preceded by `sync` over vsock, since `vm.stop` is a force stop)
8. **Save** — `image.save`, poll `image.list` until the image appears
9. **Cleanup** — `vm.delete` the intermediate VM (unless `--keep-vm`)

**Layering onto an existing image** — `--image <name>` replaces steps 1–5 with a single `vm.create --fromImage`, since that image already has macOS installed, Setup Assistant done, the agent installed and provisioning applied. This is how toolchain images are built on top of a base: minutes of decompression instead of an hour of installing. `--image` and `--ipsw` are mutually exclusive.

**Xcode installation** (`--xcode <url|path>`) runs [provision/install-xcode.sh](../provision/install-xcode.sh) inside the guest over vsock, with the source passed as an `XCODE_SRC=` line prepended to the script body (`vm.exec`'s `args` are appended to the command string, which a multi-line body cannot use). A URL is downloaded by the guest itself — no 10GB detour through the shared folder; a local path is copied into the host's shared folder and read from `/Volumes/phantom-shared`. The script expands the `.xip` (whose Apple signature `xip --expand` verifies, so it doubles as the integrity check), installs to `/Applications/Xcode.app`, then `xcode-select -s`, `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, and `DevToolsSecurity -enable` so a headless CI VM never faces an authorization prompt. Finally `xcodebuild -downloadAllPlatforms` bakes in every simulator runtime — Xcode ships with none, and paying for them once at build time beats every CI job downloading several GB before it can start.

### Image Catalog (distribution)

Users are not expected to build images. `phantom image list` shows a published catalog, and `phantom image pull <name>` fetches one by name — the same shape as `ipsw list` / `ipsw pull`.

The catalog is a one-layer OCI artifact (`vnd.monk-studio.phantom.catalog.v1+json`) living in the same registry as the images, `ghcr.io/phantom-vm/catalog:latest` by default (`PHANTOM_CATALOG` overrides it). Hosting it as an artifact keeps distribution to a single dependency, and reads are anonymous, so a fresh install can browse before it has credentials. Its entries carry a name, description, repository, sizes, and the image's **manifest digest**:

```json
{ "schemaVersion": 1,
  "images": [{ "name": "xcode-26-6", "description": "…",
               "repository": "ghcr.io/phantom-vm/xcode-26-6",
               "digest": "sha256:…", "compressedSize": 58859000000,
               "diskSize": 96636764160, "published": "2026-07-25" }] }
```

**Why the digest matters**: `image pull <name>` resolves through the catalog and pulls `repository@sha256:…`, never a tag. A digest names exact bytes, so the daemon verifies the manifest against it ([OCIRegistry.swift](../phantom/Libs/OCI/OCIRegistry.swift)), and since every layer is already verified against its own digest, that check extends integrity to the whole image. A tag pull has nothing to compare against — hence the catalog records digests. Like the IPSW catalog, the catalog only *points*.

**Staying current**: a pull writes `pulled.json` (reference, digest, date) beside the image, because nothing else preserves the digest it came from — pushing re-encodes the manifest, so the local `manifest.json` hashes to something other than what the registry stored. `image list` compares that against the catalog and reports one of three things: current, `(update available)`, or `(Downloaded, origin unknown)` for an image built locally or pulled before this record existed. `image pull <name>` then exits early when current, replaces when the digest differs, and refuses rather than guessing when the origin is unknown (`--force` overrides). Replacement deletes the local copy before downloading — no second copy on disk, so a failed pull leaves the name empty. The catalog holds one digest per name, so there is no version history to roll back to.

**Publishing** (`phantom image publish <name>`, admin-only): push the image, read the stored manifest digest back from the registry with a `HEAD` (the daemon re-encodes the manifest when pushing, so only the registry knows the bytes it kept), then rewrite the catalog artifact with that entry. The CLI speaks OCI directly for the catalog ([phantom-cli/src/lib/oci.ts](../phantom-cli/src/lib/oci.ts)) — it is a small JSON blob, and the daemon's client exists for multi-gigabyte layers. Credentials come from `PHANTOM_REGISTRY_USERNAME`/`PASSWORD` or `~/.docker/config.json`, the same sources the daemon uses.

### Registry Authentication

Auth follows the OCI Distribution Spec token flow:
1. First request returns 401 with `WWW-Authenticate` header
2. Parse header for Bearer realm, service, scope
3. Fetch token from auth endpoint (with Basic credentials if available)
4. Retry original request with `Authorization: Bearer <token>`

**Credential sources** (in priority order):
1. Explicit `--username`/`--password` flags
2. Environment variables: `PHANTOM_REGISTRY_USERNAME`, `PHANTOM_REGISTRY_PASSWORD`
3. `~/.docker/config.json` (auto-detected by registry hostname)

---

## Concurrency Model

### Threading Strategy

**Network.framework callbacks** → Background queue
**VMManager operations** → @MainActor
**State updates** → @MainActor

**Bridging Pattern**:
```swift
// Network callback (background queue)
connection.receive { data, _, _, _ in
    // Process on MainActor for VMManager access
    Task { @MainActor in
        let responseData = await self.processRequest(data)
        self.sendResponse(responseData, to: connection)
    }
}
```

### Async Patterns

**Continuation-based bridging** for callback APIs:
```swift
try await withCheckedThrowingContinuation { cont in
    VZMacOSRestoreImage.load(from: url) { result in
        cont.resume(with: result)
    }
}
```

**MainActor dispatch** for state updates:
```swift
Task { @MainActor in
    self?.state = .downloading(progress: progress)
}
```

**Progress observation** with KVO:
```swift
let observation = installer.progress.observe(\.fractionCompleted) { progress, _ in
    Task { @MainActor in
        self?.vmState = .installing(progress: progress.fractionCompleted)
    }
}
```

---

## VM Configuration

Each VM is configured with:

```swift
VZVirtualMachineConfiguration {
    platform: VZMacPlatformConfiguration
        - hardwareModel: VZMacHardwareModel (from restore image)
        - machineIdentifier: VZMacMachineIdentifier (generated or loaded)
        - auxiliaryStorage: VZMacAuxiliaryStorage (persisted)

    bootLoader: VZMacOSBootLoader()

    cpuCount: max(4, minimumAllowedCPUCount)
    memorySize: max(16GB, minimumAllowedMemorySize)

    storageDevices: [
        VZVirtioBlockDeviceConfiguration(
            attachment: VZDiskImageStorageDeviceAttachment(url: disk.img)
        )
    ]

    networkDevices: [
        VZVirtioNetworkDeviceConfiguration(
            attachment: VZNATNetworkDeviceAttachment()
        )
    ]

    keyboards: [VZMacKeyboardConfiguration()]
    pointingDevices: [VZMacTrackpadConfiguration()]

    graphicsDevices: [
        VZMacGraphicsDeviceConfiguration {
            displays: [1920x1200 @ 144 DPI]
        }
    ]

    socketDevices: [VZVirtioSocketDeviceConfiguration()]

    directorySharingDevices: [
        VZVirtioFileSystemDeviceConfiguration {
            tag: "phantom-shared"
            share: VZSingleDirectoryShare(directory: ~/phantom/shared)
        }
    ]

    entropyDevices: [VZVirtioEntropyDeviceConfiguration()]
}
```

---

## Error Handling

### VMManager Errors

```swift
enum PhantomError: LocalizedError {
    case unsupportedHardware
    case diskCreationFailed
    case vmBundleCorrupted
    case connectionClosed
}
```

### API Errors

```swift
enum APIHandlerError: LocalizedError {
    case unknownMethod(String)
    case missingParam(String)
    case invalidParams(String)
    case ipswNotFound(String)
    case vmNotFound(String)
    case vmNotRunning(String)
    case vmAlreadyExists(String)
    case cloneFailed(String)
}
```

**Error Flow**:
1. Error occurs in VMManager or handler
2. Caught by `APIHandlers.handle()`
3. Converted to `APIError` with code and message
4. Serialized to JSON response
5. Sent to client
6. CLI displays error and exits with code 1

---

## State Management

### Observable State

```swift
@MainActor
@Observable
class IPSWManager {
    private(set) var state: State = .none  // .none | .fetching | .downloading | .downloaded | .error
    private(set) var info: String = ""

    func download() async { ... }
    func list() -> [IPSWInfo] { ... }
    var downloadedPath: URL? { ... }
}

@MainActor
@Observable
class OCIImageManager {
    private(set) var state: OperationState = .idle
    // .idle | .saving(progress, message) | .pushing(progress, message)
    // | .pulling(progress, message) | .completed(message) | .error(message)

    func save(name:bundlePath:) async { ... }
    func list() -> [ImageInfo] { ... }
    func delete(name:) throws { ... }
    func createVM(fromImage:vmsDir:) async throws -> (String, URL) { ... }
    func push(name:reference:username:password:) async { ... }
    func pull(reference:name:username:password:) async { ... }
}

@MainActor
@Observable
class VMManager {
    struct VMInstance {
        let vmId: String
        let bundlePath: URL
        var state: VMState
        var virtualMachine: VZVirtualMachine?
    }

    let ipswManager: IPSWManager
    let imageManager: OCIImageManager
    private(set) var vmInstances: [String: VMInstance] = [:]
    private(set) var displayedVMId: String? = nil
    private(set) var hasExistingVM: Bool = false
    private(set) var logs: [String] = []
}
```

**Multi-VM Architecture**:
- Each VM tracked independently via `VMInstance` in `vmInstances` dictionary
- Key is VM ID (e.g., "vm-abc123")
- Each instance maintains its own state, virtual machine reference, and bundle path
- Multiple VMs can exist simultaneously, but typically only one runs at a time
- `displayedVMId` tracks which VM's display window should be shown

**State Transitions**:

**IPSW Download**:
```
.none → .fetching → .downloading(0.0) → ... → .downloading(1.0) → .downloaded
                                   ↓
                              .error(message)
```

**VM Creation**:
```
.none → .creating → .installing(0.0) → ... → .installing(1.0) → .running
                                    ↓
                               .error(message)
```

**VM Lifecycle**:
```
.running → .stopping → .stopped
```

### GUI Reactivity

SwiftUI views automatically update when observable state changes:

```swift
@Bindable var vm: VMManager

var body: some View {
    if case .downloading(let progress) = vm.ipswManager.state {
        ProgressView(value: progress)
    }

    // Display all VMs
    ForEach(vm.listVMs(), id: \.id) { vmInfo in
        let instance = vm.vmInstances[vmInfo.id]
        HStack {
            Text(vmInfo.id)
            if let instance = instance {
                Text(instance.state.apiString)
                if instance.state == .running {
                    Button("Stop") {
                        Task { await vm.stopVM(vmId: vmInfo.id) }
                    }
                }
            }
        }
    }

    Button("Create VM") {
        Task { await vm.createAndStartVM() }
    }
    .disabled(!canCreateVM)
}
```

---

## Security & Isolation

### Sandbox

- App runs in macOS App Sandbox
- Required entitlements: `com.apple.security.virtualization`, `com.apple.security.network.client`
- No file system restrictions (sandbox disabled for VM file access)

### Network Isolation

- TCP server binds to localhost only (not accessible remotely)
- VM network uses NAT (isolated from host, internet access only)
- vsock is VM-to-host only (no external access)

### Guest Agent

- Runs as root inside VM (required for launchd daemon)
- Executes arbitrary commands via `/bin/sh -c` (trusted environment)
- No authentication on vsock connection (VM-to-host is trusted)

---

## Technical Stack

**Languages**: Swift, TypeScript
**Runtime**: macOS 13+, Bun
**Frameworks**:
- Virtualization.framework (VM management)
- Network.framework (TCP server)
- SwiftUI (GUI)
- Foundation (core utilities)

**Zero External Dependencies**: No third-party libraries, only Apple frameworks and Bun runtime. OCI support uses `Foundation.URLSession` for HTTP, `Compression` framework for LZ4, and `CommonCrypto` for SHA-256 digests.

---

## Design Decisions

### One Request Per Connection

**Rationale**: Simplicity over performance. CLI usage doesn't require persistent connections.

**Trade-off**: Higher latency from connection overhead, but acceptable for infrequent CLI operations.

### Streaming for Command Execution

**Rationale**: Long-running commands (e.g., xcodebuild) need real-time output. The `vm.execStream` endpoint keeps the TCP connection open and sends newline-delimited JSON chunks. Other endpoints remain stateless (one request, one response).

**Trade-off**: Streaming adds protocol complexity but only for the exec path. Non-streaming `vm.exec` is preserved for backward compatibility.

### Newline-Delimited JSON

**Rationale**: Simple, universal, human-readable. Works with netcat for debugging.

**Trade-off**: Less efficient than binary protocols, but adequate for low-volume API traffic.

### MainActor for Everything

**Rationale**: Eliminates race conditions. Matches SwiftUI's threading model.

**Trade-off**: All API requests serialize through main thread. Future enhancement: Move heavy computation to background.

### Multi-VM State Management

**Implementation**: VMManager tracks multiple VMs via `vmInstances` dictionary. Each VM has independent state.

**Rationale**: Enables managing multiple VMs concurrently - create, clone, list, and control multiple VMs from single daemon.

**Trade-off**: Increased state complexity, but enables essential VM management workflows like cloning and fleet management.

**Note**: While multiple VMs can exist, typically only one runs at a time due to resource constraints.

---

## File Locations

### Source Code

```
phantom/
├── phantom/                   # Daemon app
│   ├── phantomApp.swift      # Entry point
│   ├── ContentView.swift     # SwiftUI GUI
│   ├── APIHandlers.swift     # API request routing
│   ├── APIModels.swift       # JSON protocol definitions
│   └── Libs/
│       ├── VMManager.swift   # VM lifecycle management
│       ├── IPSWManager.swift # IPSW download and listing
│       ├── TCPServer.swift   # Network.framework TCP server
│       └── OCI/
│           ├── OCITypes.swift          # Manifest, descriptor, media types
│           ├── OCIReference.swift      # Registry reference parsing
│           ├── OCIAuth.swift           # Bearer/Basic auth + Docker config
│           ├── OCIRegistry.swift       # OCI Distribution API client
│           ├── OCIDiskLayerizer.swift  # Disk chunking + LZ4 compression
│           └── OCIImageManager.swift   # Image CRUD + push/pull
│
├── phantomTests/             # Unit tests
│   ├── OCIReferenceTests.swift
│   ├── OCITypesTests.swift
│   └── OCIDiskLayerizerTests.swift
│
├── phantom-agent/            # Guest agent
│   └── Sources/main.swift   # vsock server (180 lines)
│
└── phantom-cli/              # CLI tool
    └── src/
        ├── main.ts          # CLI entry point and command registry
        ├── router.ts        # Command routing
        ├── lib/api.ts       # TCP client (batch + streaming)
        └── commands/
            ├── vm.ts            # create, list, start, stop, exec, display, vnc, boot-script, screenshot, delete
            ├── image.ts         # list, delete, save, push, pull
            ├── build.ts         # image build orchestrator
            ├── ipsw.ts          # IPSW management
            ├── gitlab-runner.ts # GitLab custom executor
            └── health.ts        # Daemon health check
```

### Runtime Data

```
~/Library/Application Support/phantom/
├── ipsws/          # IPSW files
├── vms/            # VM bundles
├── images/         # Local OCI images
└── shared/         # Guest agent files
```

### Installation

```
/usr/local/bin/phantom-agent              # Inside VMs only
/Library/LaunchDaemons/com.monk.phantom-agent.plist
/var/log/phantom-agent.{out,err}.log
```
