# API

The two protocols the daemon speaks — TCP to the CLI, vsock to the guest agent —
and every endpoint behind the TCP one.

## API Request Lifecycle

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

## Communication Protocols

### TCP API Protocol (Daemon ↔ CLI)

**Transport**: TCP on localhost:9090
**Format**: Newline-delimited JSON
**Pattern**: One request per connection (stateless)
**Size**: A request is read until its newline, across as many reads as that
takes, and is capped at 16MB. Requests are not always small — `vm.exec` and
`vm.execStream` carry the command in full, and a CI job's whole script arrives
base64-encoded inside one. Both ends write in as many passes as the socket
accepts, rather than assuming one write leaves nothing behind.

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
- **Response**: `{"status": "ok", "version": "1.2.3"}` — the app's `CFBundleShortVersionString` (`MARKETING_VERSION`, set by `scripts/set-version.sh` at release time)

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
- **Params**: Exactly one of `ipswId` (string), `sourceVmId` (string), or `fromImage` (string); optional `name` (string), `cpuCount` (int), `memoryGB` (number)
- **Purpose**: Create a new VM from an IPSW, by cloning an existing VM, or from a saved OCI image
- **Sizing and naming**: `name` becomes the VM's id and its bundle directory, so it is restricted to letters, digits, `-` and `_` and rejected if a VM already has it; omitted, a `vm-xxxxxxxx` is generated. `cpuCount` and `memoryGB` are range-checked against the host (the framework's CPU ceiling capped at the machine's core count, memory at installed RAM) and stored in the bundle's `vm.json`, so they apply to every later start rather than only the first. Passing one leaves the other at its default. A clone without them inherits the source VM's sizing.
- **Implementation**:
  - `ipswId`: Validates IPSW exists, then returns a generated `vmId` immediately and runs the ~20-minute install in a background task. Poll `vm.list` for the VM's state (`creating` → `installing(N%)` → `running`). After the install finishes, the installer's VM instance is torn down and a **fresh** `VZVirtualMachine` is booted from the bundle — the installer's own instance flakily hangs on a black screen instead of reaching Setup Assistant; a clean restart is reliable.
  - `sourceVmId`: APFS CoW clone of existing VM bundle — the one synchronous source, since a CoW clone is instant
  - `fromImage`: Same shape as `ipswId` — the `vmId` comes back as soon as the image is confirmed to exist, and a background task decompresses the image chunks (in parallel) into a new VM bundle, restores the image's MachineIdentifier and boots it. Poll `vm.list` for the state (`restoring(N%)` → `creating` → `running`). Restoring the 58.9GB `xcode-26-6` into a 90GB disk takes minutes, so the caller must not be holding a socket open across it: the VM instance is registered *before* the restore begins, so it is listed the whole way through and a caller that times out or disconnects can still find it. Restore progress rides on the VM's own state rather than `image.status` — that slot is single-occupancy, and a restore has no business colliding with a concurrent pull.
- **Response**: `{"status": "started"|"running", "message": "...", "vmId": "vm-..."}`
- **CLI**: `phantom vm deploy --image <name> [--name <id>] [--cpu <n>] [--memory <gb>]`

### vm.start
- **Params**: `vmId` (string)
- **Purpose**: Start an existing stopped VM
- **Implementation**: Loads VM bundle, rebuilds the VM configuration, calls `VZVirtualMachine.start()`
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
- **Params**: `vmId` (string), `name` (string), `replace` (bool, optional — default false)
- **Purpose**: Save a stopped VM as a local OCI image
- **Implementation**: Fire-and-forget. Reads HardwareModel (base64-encoded into config JSON), copies AuxiliaryStorage as nvram.bin, chunks disk.img into 512MB LZ4-compressed layers, writes manifest.json. An existing name is an error unless `replace` is set, in which case the new copy is built in a hidden staging directory and moved into place only once the manifest is written — a failed save leaves the old image intact, at the cost of room for both while it runs. Replacing drops the old `pulled.json`, since the locally built bytes no longer come from that digest.
- **Naming**: `name` becomes the image's directory under `images/`, so it takes the same characters as a VM's name — letters, digits, `-` and `_`, up to 64 — and anything else is rejected before the save starts. The rule is enforced in the image manager, at the point a name turns into a path, so `image.delete`, `image.push` and `image.pull` hold to it too; the handler checks as well, so a fire-and-forget call answers with the error rather than `started`.
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
- **Implementation**: Fire-and-forget. Fetches manifest, downloads config/nvram/disk blobs, saves to local image directory. An omitted `name` is taken from the last path segment of the reference and has to satisfy the same naming rule as `image.save` — the registry picked it, so it is checked like any other input.
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
