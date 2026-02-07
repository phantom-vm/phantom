# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

### VM Creation (Planned)

Create VMs from IPSW images or clone existing VMs:

```bash
# Create from IPSW image
phantom create --from-ipsw <ipsw-id>

# Clone from existing VM (uses APFS copy-on-write)
phantom create --from-vm <vm-id>
```

**IPSW Management:**
```bash
phantom ipsw pull          # Download macOS restore image from Apple
phantom ipsw list          # List available IPSW images
```

**Implementation:**
- Rename `image` commands to `ipsw` throughout CLI
- Replace `run <IMAGE>` with `create --from-ipsw <ipsw-id>`
- Add `create --from-vm <vm-id>` for cloning functionality
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
phantom create --from-vm <template-vm> --rm -- <command>
```

**How it works:**
- Clone template VM → run command → delete clone on exit
- Perfect for CI/CD, testing, one-off tasks
- Like `docker run --rm` but for full macOS VMs

**Requires:** VM creation implementation
