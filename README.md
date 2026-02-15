# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

### Ephemeral VMs

Run temporary VMs that auto-delete after use:

```bash
phantom create --from-vm <template-vm> --rm -- <command>
```

**How it works:**
- Clone template VM (APFS CoW, instant) → boot → run command → delete clone
- Perfect for CI/CD, testing, one-off tasks
- Like `docker run --rm` but for full macOS VMs

### Command Execution

Run commands inside running VMs:

```bash
phantom exec <vm-id> -- <command>
```
