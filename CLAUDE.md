# Claude Development Guide

## Project Overview

**GTD project id**: `PHANTOM` (use this when filing/updating tickets for this project)

**Never reference ticket numbers (`PHANTOM-N`) in documentation** — README, docs/, code comments. The ticket system is internal; the repo is public, and a `PHANTOM-5` means nothing to an outside reader. Commit subjects keep their `(PHANTOM-N)` suffix — that convention stays.

Phantom is the macOS VM orchestrator, built with Apple's Virtualization.framework. It consists of three components:

1. **phantom daemon** - SwiftUI app with GUI and TCP API server
2. **phantom-cli** - Bun-based CLI tool
3. **phantom-agent** - Runs inside VMs for command execution

## Architecture Documentation

**📖 For overall architecture and dataflow, see [docs/design/](docs/design/)**

The design docs are split by subject, with [docs/design/README.md](docs/design/README.md)
holding the system overview, technical stack and design decisions:

- [core.md](docs/design/core.md) — daemon architecture, VM lifecycle and configuration, storage layout, guest agent, concurrency, state management, error handling, security
- [api.md](docs/design/api.md) — TCP and vsock protocols, every API endpoint, the request lifecycle
- [images.md](docs/design/images.md) — OCI image format, disk layerization, image flows, the published catalog, automated image building
- [cli.md](docs/design/cli.md) — command flow, admin mode, self-update
- [ui.md](docs/design/ui.md) — the three-column GUI and its reactivity

## Important Guidelines

### When Making Architecture Changes

**⚠️ Always update the relevant doc under [docs/design/](docs/design/) when making architectural changes**

| Change | Doc |
|--------|-----|
| Adding/removing components | `README.md` |
| Design decision or trade-off worth recording | `README.md` |
| Changing communication protocols | `api.md` |
| Adding new API endpoints | `api.md` |
| Modifying data flows | `core.md` (VM lifecycle), `api.md` (request lifecycle) |
| Changing storage layout | `core.md` |
| Updating threading/concurrency model | `core.md` |
| Modifying state management | `core.md` |
| Changing the image format, catalog or build pipeline | `images.md` |
| Adding or reshaping CLI commands | `cli.md` |
| Changing the GUI's structure | `ui.md` |

### Project Structure

```
phantom/
├── phantom/          # Main daemon app (Swift)
├── phantom-agent/    # Guest agent (Swift)
├── phantom-cli/      # CLI tool (Bun/TypeScript)
├── README.md        # User-facing overview
├── docs/            # design/, authoring-images.md, integration/
└── CLAUDE.md        # This file
```

## Development Workflow

1. **Before making changes**: Read the relevant doc under docs/design/ to understand current architecture
2. **During development**: Follow existing patterns (see docs/design/ for details)
3. **After changes**: Update docs/design/ if architecture was modified
4. **After phantom-cli changes**: Run `cd phantom-cli && bun run install-bin` to rebuild and install the binary
5. **Committing**: Follow conventional commit format

## Key Technologies

- **Swift**: Daemon and guest agent
- **Virtualization.framework**: VM management
- **Network.framework**: TCP server
- **SwiftUI**: GUI with @Observable state
- **Bun**: CLI tool runtime
- **JSON**: All communication protocols (newline-delimited)

## Quick Start

**Run daemon**: Open phantom.xcodeproj in Xcode

**Run CLI**:
```bash
cd phantom-cli
bun run src/main.ts health
```

**Deploy guest agent**: VMs bootstrap it from the published `phantom-agent-install.sh`
release asset; see [phantom-agent/README.md](phantom-agent/README.md) for the
dev override.

## Additional Resources

- [README.md](README.md) - User-facing overview and quick start
- [docs/design/](docs/design/) - **Architecture documentation** (main reference)
- [docs/authoring-images.md](docs/authoring-images.md) - Building and publishing images (admin)
- [docs/releasing.md](docs/releasing.md) - Cutting a release (version bump + GitHub release, one workflow)
- [phantom-agent/README.md](phantom-agent/README.md) - Guest agent setup
