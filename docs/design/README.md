# Phantom Design Document

The macOS VM orchestrator — built on Apple's Virtualization.framework, with a TCP API and CLI interface.

This directory is the architecture reference, split by subject:

| Document | Covers |
|----------|--------|
| [core.md](core.md) | Daemon architecture, VM lifecycle and configuration, storage layout, guest agent, concurrency, state management, error handling, security |
| [api.md](api.md) | TCP and vsock protocols, every API endpoint, the request lifecycle |
| [images.md](images.md) | OCI image format, disk layerization, image flows, the published catalog, automated image building |
| [cli.md](cli.md) | Command flow, admin mode, self-update |
| [ui.md](ui.md) | The three-column GUI and its reactivity |

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
