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
├── VMManager.swift       # VM lifecycle management
├── TCPServer.swift       # Network.framework TCP server
├── APIHandlers.swift     # API request routing
└── APIModels.swift       # JSON protocol definitions
```

**State Management**:
- Uses `@Observable` macro for reactive state
- All state mutations happen on `@MainActor`
- Tracks multiple VMs via `vmInstances` dictionary
- Observable properties: `imageState`, `vmInstances`, `logs`, etc.

**Initialization Flow**:
1. App launches → `phantomApp.body` renders
2. `.task {}` modifier creates `TCPServer(vmManager: vm)`
3. Server starts listening on localhost:9090
4. GUI displays current VM state

### CLI (Bun/TypeScript)

Single-file CLI that sends JSON-RPC requests to the daemon.

**File**: `phantom-cli/src/main.ts` (260 lines)

**Command Flow**:
1. Parse command-line arguments
2. Construct JSON request: `{"method": "vms.list"}`
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
 │  vms.create            │                    │
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
 │  (poll vms.list)        │  Installing...     │
 │────────────────────────▶│────────────────────▶│
 │                         │                    │
 │  {"state":"running"}    │                    │
 │◀────────────────────────┤                    │
```

**Listing VMs**:

```
CLI                     Daemon                  Filesystem
 │                         │                    │
 │  vms.list              │                    │
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
│    - Parse JSON: {"method":"vms.list"}                    │
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
├── images/                    # Downloaded IPSW files
│   ├── 25C56.ipsw            # macOS restore image (14-18GB)
│   └── 24C61.ipsw
│
├── vms/                      # VM bundles
│   ├── vm-abc123/
│   │   ├── disk.img          # 64GB sparse disk image
│   │   ├── AuxiliaryStorage  # Binary blob
│   │   ├── MachineIdentifier # Binary blob
│   │   └── HardwareModel     # Binary blob
│   │
│   └── vm-def456/
│       └── ...
│
└── shared/                   # Mounted in all VMs
    ├── phantom-agent         # Guest agent binary
    ├── install.sh            # Installation script
    ├── uninstall.sh
    └── com.monk.phantom-agent.plist
```

**VM Bundle Contents**:
- `disk.img` - Created via `ftruncate()`, 64GB sparse file
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
  "method": "vms.create",
  "params": {
    "imageId": "25C56"
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
    "code": "image_not_found",
    "message": "Image not found: 25C56"
  }
}
```

### vsock Protocol (Daemon ↔ Guest)

**Transport**: vsock on port 9001
**Format**: Newline-delimited JSON
**Pattern**: Multiple commands per connection

**Request**:
```json
{
  "command": "ls",
  "args": ["-la", "/tmp"]
}
```

**Response**:
```json
{
  "stdout": "total 0\ndrwx... .\n",
  "stderr": "",
  "exitCode": 0
}
```

---

## API Endpoints

### health
- **Purpose**: Check daemon status
- **Response**: `{"status": "ok", "version": "1.0.0"}`

### images.list
- **Purpose**: List downloaded IPSW files
- **Implementation**: Scans `~/Library/Application Support/phantom/images/`
- **Response**: `{"images": [{"id": "25C56", "path": "...", "size": 17000000000}]}`

### images.pull
- **Purpose**: Download macOS restore image
- **Implementation**:
  - Fetches `VZMacOSRestoreImage.latestSupported`
  - Downloads via URLSession with progress tracking
  - Returns immediately (async operation)
- **Response**: `{"status": "started", "message": "Image download started"}`

### vms.list
- **Purpose**: List all VM bundles
- **Implementation**: Scans `~/Library/Application Support/phantom/vms/`
- **Response**: `{"vms": [{"id": "vm-abc", "path": "...", "state": "running"}]}`

### vms.create
- **Params**: `imageId` (string)
- **Purpose**: Create and start new VM
- **Implementation**:
  - Validates image exists
  - Creates VM bundle directory
  - Creates disk image
  - Installs macOS
  - Auto-starts VM
  - Returns immediately (async operation)
- **Response**: `{"status": "started", "message": "VM creation started"}`

### vms.stop
- **Params**: `vmId` (string)
- **Purpose**: Stop running VM
- **Implementation**: Calls `VZVirtualMachine.stop()`
- **Response**: `{"status": "stopped", "vmId": "vm-abc"}`

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
    self?.imageState = .downloading(progress: progress)
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
    memorySize: max(8GB, minimumAllowedMemorySize)

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
    case imageNotFound(String)
    case vmNotFound(String)
    case vmNotRunning(String)
    case vmAlreadyExists(String)
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
class VMManager {
    struct VMInstance {
        let vmId: String
        let bundlePath: URL
        var state: VMState
        var virtualMachine: VZVirtualMachine?
    }

    private(set) var imageState: ImageState = .none
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

**Image Download**:
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
    if case .downloading(let progress) = vm.imageState {
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

**Zero External Dependencies**: No third-party libraries, only Apple frameworks and Bun runtime.

---

## Design Decisions

### One Request Per Connection

**Rationale**: Simplicity over performance. CLI usage doesn't require persistent connections.

**Trade-off**: Higher latency from connection overhead, but acceptable for infrequent CLI operations.

### No Streaming Updates

**Rationale**: Stateless API is simpler. Long operations return immediately with "started" status.

**Trade-off**: CLI must poll for status updates. Future enhancement: WebSocket for real-time updates.

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
│   ├── phantomApp.swift      # Entry point (40 lines)
│   ├── ContentView.swift     # GUI (200 lines)
│   ├── VMManager.swift       # VM management (600 lines)
│   ├── TCPServer.swift       # Network server (200 lines)
│   ├── APIHandlers.swift     # Request handlers (170 lines)
│   └── APIModels.swift       # Protocol structures (90 lines)
│
├── phantom-agent/            # Guest agent
│   └── Sources/main.swift   # vsock server (180 lines)
│
└── phantom-cli/              # CLI tool
    └── src/main.ts          # CLI implementation (260 lines)
```

### Runtime Data

```
~/Library/Application Support/phantom/
├── images/          # IPSW files
├── vms/            # VM bundles
└── shared/         # Guest agent files
```

### Installation

```
/usr/local/bin/phantom-agent              # Inside VMs only
/Library/LaunchDaemons/com.monk.phantom-agent.plist
/var/log/phantom-agent.{out,err}.log
```
