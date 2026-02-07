# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

### VM Cloning (Planned)

Fast VM cloning using APFS copy-on-write:

```bash
phantom clone <source-vm> <new-vm>
```

**Implementation:**
- Copy VM bundle files (disk.img, AuxiliaryStorage, HardwareModel)
- Regenerate MachineIdentifier for unique VM identity
- Leverage APFS CoW - clones don't claim space until disk writes occur

**Benefits:**
- Instant VM duplication
- Space-efficient (only changed blocks consume storage)
- Create reusable VM templates

### Ephemeral VMs (Planned)

Run temporary VMs that auto-delete after use:

```bash
phantom run --rm <template-vm> <command>
```

**How it works:**
- Clone template VM → run command → delete clone on exit
- Perfect for CI/CD, testing, one-off tasks
- Like `docker run --rm` but for full macOS VMs

**Requires:** VM cloning implementation
