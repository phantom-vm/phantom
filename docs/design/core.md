# Core

The daemon and the guest agent: how a VM is built, configured, stored and tracked.
For the protocols and endpoints they expose, see [api.md](api.md).

## Daemon (Swift App)

The daemon is a standard macOS SwiftUI application with three main subsystems:

**File Structure**:
```
phantom/
├── phantomApp.swift      # App entry point, initializes TCPServer
├── ContentView.swift     # Three-column GUI shell (sidebar / list / detail)
├── Views/                # The columns and their panes
│   ├── SidebarView.swift     # VMs/Images with live counts, then a Daemon group
│   ├── VMListView.swift      # VM list column, its rows and the filter menu
│   ├── VMDetailView.swift    # VM metadata, actions, exec console
│   ├── ImagesView.swift      # Local/catalog image columns and detail panes
│   ├── CreateVMSheet.swift   # New VM: name, local image, CPU, memory
│   ├── LogLinesView.swift    # Log viewer: row list + selected-line detail pane
│   ├── LogTableView.swift    # NSTableView-backed log list, O(changed) updates
│   ├── IntegrationView.swift # GitLab Runner (Info/Log tabs), GitHub placeholder
│   └── VMDisplayView.swift   # VZVirtualMachineView wrapper
├── APIHandlers.swift     # API request routing
├── APIModels.swift       # JSON protocol definitions
└── Libs/
    ├── VMManager.swift   # VM lifecycle management
    ├── VMSettings.swift  # Per-VM CPU/memory (vm.json) + VM name rules
    ├── LogBuffer.swift   # Bounded log with stable line ids
    ├── LineAssembler.swift # Reassembles piped lines, strips ANSI
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
        ├── OCIImageManager.swift   # Image CRUD + push/pull orchestration
        └── CatalogManager.swift    # Fetches the published image catalog

phantomTests/             # Unit tests
├── OCIReferenceTests.swift
├── OCITypesTests.swift
└── OCIDiskLayerizerTests.swift
```

The GUI shell those `Views/` make up is described in [ui.md](ui.md).

**Initialization Flow**:
1. App launches → `phantomApp.body` renders
2. `.task {}` modifier creates `TCPServer(vmManager: vm)`
3. Server starts listening on localhost:9090
4. GUI displays current VM state

## Guest Agent (Swift)

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

**Installed inside the VM only**:
```
/usr/local/bin/phantom-agent
/Library/LaunchDaemons/com.monk.phantom-agent.plist
/var/log/phantom-agent.{out,err}.log
```

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
│   │   ├── HardwareModel     # Binary blob
│   │   └── vm.json           # CPU count + memory size (absent = 4 / 16GB)
│   │
│   └── vm-def456/
│       └── ...
│
├── images/                   # Local OCI images
│   ├── macos-base/
│   │   ├── manifest.json     # OCI manifest (layers + digests)
│   │   ├── config.json       # VM config (HardwareModel + MachineIdentifier as base64)
│   │   ├── nvram.bin         # AuxiliaryStorage
│   │   ├── pulled.json       # Pulled images only: reference, digest, date
│   │   └── disk/             # LZ4-compressed disk chunks (zero chunks absent)
│   │       ├── 000.lz4
│   │       ├── 002.lz4
│   │       └── ...
│   └── macos-dev/
│       └── ...
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
- `MachineIdentifier` - The machine identity (an ECID) the guest sees
- `HardwareModel` - CPU/hardware configuration
- `vm.json` - `VMSettings`: the VM's CPU count and memory size

`vm.json` has to exist because a VM is configured from scratch on *every* start,
not just at creation — without a record on disk, a VM sized at creation would
quietly revert to the defaults on its next boot. A bundle without the file (any
VM created before it existed) reads back as 4 CPUs / 16GB, exactly what used to
be hardcoded, so nothing resizes underneath an existing VM. Values are clamped
to what the host allows on the way in and on the way out, and a clone inherits
its source's sizing.

`MachineIdentifier` **travels with the disk** — it is carried into an image on
save, restored from the image, and copied by a clone, never regenerated. The
identifier is an ECID, the machine identity the guest reads, and macOS ties part
of its first-run state to it: hand a disk that already finished Setup Assistant
to a VM with a fresh ECID and the guest decides it woke up on new hardware, then
re-runs the hardware-tied panes — Software Update, Apple Account, FileVault — on
the next login. Every VM off that image lands in Setup Assistant instead of the
desktop, whatever the disk says. Sharing one identifier across the VMs restored
from an image is harmless: nothing outside the guest keys off the ECID, and the
identities that do have to stay unique (bundle id, MAC address) are assigned
elsewhere.

VMs get no host directory share: everything the guest needs arrives over the
network (the agent bootstrap fetches the published `phantom-agent-install.sh` release
asset; a local `--xcode` .xip is served over an ephemeral HTTP server) or over
vsock. A VirtioFS share would expose a host directory read-write to CI VMs
running untrusted code.

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

    // No directorySharingDevices — see Storage Layout

    entropyDevices: [VZVirtioEntropyDeviceConfiguration()]
}
```

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

## State Management

- Uses `@Observable` macro for reactive state
- All state mutations happen on `@MainActor`
- `IPSWManager` owns IPSW download state, referenced by `VMManager.ipswManager`
- `OCIImageManager` owns image operations state, referenced by `VMManager.imageManager`
- `CatalogManager` owns the fetched catalog, referenced by `VMManager.catalogManager`
- `VMManager` tracks multiple VMs via `vmInstances` dictionary
- Observable properties: `ipswManager.state`, `vmInstances`, `logs`, etc.

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
    func restore(image:into:progress:) async throws { ... }
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

**VM Creation** — from an IPSW:
```
.none → .creating → .installing(0.0) → ... → .installing(1.0) → .running
                                    ↓
                               .error(message)
```

**VM Creation** — from an image (`vm.create --fromImage`). The instance exists in
this state from the moment `vm.create` answers, so the restore is visible in
`vm.list` rather than happening inside a call the caller is blocked on:
```
.restoring(0.0) → ... → .restoring(0.95) → .stopped → .creating → .running
                     ↓
                .error(message)
```

**VM Lifecycle**:
```
.running → .stopping → .stopped
```

How the GUI follows this state without a notification path of its own is in
[ui.md](ui.md).

---

## Logs

There are **two** logs, not one, because the GitLab runner is a separate process:

- `VMManager.logs` — the daemon's own events. VM lifecycle, image operations, IPSW
  downloads, and the runner's state transitions (started, stopped, exited
  unexpectedly).
- `GitLabRunnerManager.output` — the runner's stdout/stderr plus that manager's own
  lifecycle messages.

They were one array, with the runner's lines tagged `[gitlab-runner]` and the GUI
recovering them by `contains`. Splitting them fixed four things at once:

- **Volume is asymmetric.** The daemon logs sparse discrete events; the runner emits
  a continuous stream. Mixed, the daemon's own events were buried — the log page
  opened on three daemon lines followed by screens of runner output.
- **Lifecycles are independent.** The runner starts, stops and crashes on its own
  schedule, so its log has its own beginning and end.
- **Ownership was inverted.** The manager owns the process, so it should own the
  output. Borrowing the daemon's sink is why the prefix existed, and the prefix is
  why a view had to sniff strings — with `contains`, not even a prefix match, so a
  VM's own output mentioning that literal would have been miscaptured.
- **It did not generalise.** A GitHub runner would have been a third prefix in the
  same array.

Both are a `LogBuffer` ([LogBuffer.swift](../../phantom/Libs/LogBuffer.swift)), which
is bounded and hands out stable, **contiguous** per-line ids — contiguity is what lets
the log table compute what changed arithmetically instead of diffing (see
[ui.md](ui.md#daemon-log)). Both properties exist for the GUI: a
daemon runs for days and the runner streams continuously, so an unbounded array grows
for the process lifetime; and identifying rows by array offset would make every
visible row look changed each time the buffer trims, so the cap itself would have
caused periodic full list rebuilds. Trimming happens in blocks so the runner's many
appends do not each shift the whole array, and the timestamp formatter is made once
rather than per line.

The runner's pipe goes through `LineAssembler`
([LineAssembler.swift](../../phantom/Libs/LineAssembler.swift)) on the way in, which
handles two things `availableData` forces on a reader: read boundaries are not line
boundaries, so a line spanning two reads would be logged as two; and gitlab-runner
colours its output, with the escape sequences landing inside the `key=value` pairs it
logs. Both are dealt with before the text is stored, so every reader gets whole clean
lines.

Neither log is persisted or exposed over the API — they are in-memory, for the
current run, readable only in the GUI.

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
