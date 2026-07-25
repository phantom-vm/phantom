# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Quick start

Nothing to build: images are published, and `image list` reads the catalog
anonymously, so this works on a machine with no credentials and no IPSW.

```
phantom image list                       # browse the catalog
phantom image pull xcode-26-6            # 58.9GB, pinned to a manifest digest
phantom vm deploy --image xcode-26-6     # boot a VM from it
phantom vm exec <vm-id> -- xcodebuild -version
```

`xcode-26-6` is macOS 26 with Xcode 26.6 and every simulator runtime
(iOS/tvOS/watchOS/visionOS) already installed, at
[ghcr.io/phantom-vm/xcode-26-6](https://github.com/orgs/phantom-vm/packages).
Pulls go by digest, never by tag, so the daemon verifies the manifest and every
layer against the catalog's published digest.

## Usage

Run commands inside a VM over vsock — no SSH, no guest setup:

```
phantom vm exec <vm-id> -- sw_vers                      # run a command (as root)
phantom vm exec <vm-id> --user admin -- open -a Notes   # run as the admin GUI user
```

Manage VMs and images:

```
phantom vm list | start | stop | delete
phantom vm vnc <id>              # open a VNC session to the VM's display
phantom vm screenshot <id>       # capture its framebuffer
phantom image list | pull | delete
```

A VM can also come from an existing one, as a fast APFS copy-on-write clone:

```
phantom vm deploy --template-vm <vm-id>
```

## GitLab CI

Turn the Mac into a GitLab runner where every job gets a fresh VM, created from
an image and deleted afterwards:

```
phantom gitlab-runner setup --token glrt-xxx    # jobs pick their VM via 'image: <name>'
```

See [GitLab CI Integration](docs/integration/gitlab.md) for the setup and how
jobs select an image.

## Under the hood

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/` — images as LZ4-chunked
  layers, VM bundles as sparse disks
- Host↔guest over vsock via a small guest agent; no SSH, no port forwarding

## Documentation

- [design.md](docs/design.md) — architecture, storage layout, protocols, image catalog format
- [GitLab CI Integration](docs/integration/gitlab.md) — Phantom as a GitLab custom executor
- [Authoring and Publishing Images](docs/authoring-images.md) — for whoever produces the images (admin)
