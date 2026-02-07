# Claude Development Guide

## Project Overview

Phantom is a macOS VM manager built with Apple's Virtualization.framework. It consists of three components:

1. **phantom daemon** - SwiftUI app with GUI and TCP API server
2. **phantom-cli** - Bun-based CLI tool
3. **phantom-agent** - Runs inside VMs for command execution

## Architecture Documentation

**📖 For overall architecture and dataflow, see [DESIGN.md](DESIGN.md)**

The DESIGN.md file contains comprehensive documentation of:
- System architecture and component interactions
- Data flow diagrams
- Storage layout
- Communication protocols (TCP API, vsock)
- API endpoints
- Concurrency model
- State management
- Design decisions and trade-offs

## Important Guidelines

### When Making Architecture Changes

**⚠️ Always update [DESIGN.md](DESIGN.md) when making architectural changes**

This includes:
- Adding/removing components
- Changing communication protocols
- Modifying data flows
- Adding new API endpoints
- Changing storage layout
- Updating threading/concurrency model
- Modifying state management

### Project Structure

```
phantom/
├── phantom/          # Main daemon app (Swift)
├── phantom-agent/    # Guest agent (Swift)
├── phantom-cli/      # CLI tool (Bun/TypeScript)
├── README.md        # Progress and setup
├── DESIGN.md        # Architecture documentation
└── CLAUDE.md        # This file
```

## Development Workflow

1. **Before making changes**: Read DESIGN.md to understand current architecture
2. **During development**: Follow existing patterns (see DESIGN.md for details)
3. **After changes**: Update DESIGN.md if architecture was modified
4. **Committing**: Follow conventional commit format

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

**Deploy guest agent**:
```bash
cd phantom-agent
./init-host-shared-folder.sh
# Then install in VM
```

## Additional Resources

- [README.md](README.md) - Project overview and progress tracking
- [DESIGN.md](DESIGN.md) - **Architecture documentation** (main reference)
- [phantom-agent/README.md](phantom-agent/README.md) - Guest agent setup
