# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Documentation

- [Create a Ready-to-Use Phantom Image](docs/create-image.md) — author a base image from an IPSW and publish it (admin)
- [GitLab CI Integration](docs/integration/gitlab.md) — use Phantom as a GitLab custom executor for ephemeral macOS CI jobs
- [DESIGN.md](DESIGN.md) — architecture, storage layout, protocols, and the image catalog format

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

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
phantom vm delete <vm-id>
```

Other deploy sources:

```
phantom vm deploy --ipsw <ipsw-id>          # fresh macOS install from an IPSW
phantom vm deploy --template-vm <vm-id>     # fast APFS copy-on-write clone
```

Manage images, VMs, and IPSWs:

```
phantom image list | save | push | pull | delete
phantom vm list | start | stop | vnc | screenshot
phantom ipsw list | pull
```

Authoring commands (`ipsw`, `image build`, `image publish`) exist only in the
admin CLI build from `bun run install-bin`; the user build from
`bun run build-user-bin` omits them, since regular users pull a published image
rather than making one.

Turn the Mac into a GitLab CI runner (auto-downloads and manages `gitlab-runner`, each job runs in a fresh VM):

```
phantom gitlab-runner setup --token glrt-xxx    # jobs pick their VM via 'image: <name>'
```

## Authoring and publishing images (admin)

Build a base image from a downloaded IPSW with one unattended command (run from
the repo root so it finds `provision/`), layer a toolchain onto it, then publish:

```
phantom image build macos-tahoe --agent-dir phantom-agent
phantom image build xcode-26-6 --image macos-tahoe --xcode <url-or-path-to-xip>
phantom image publish xcode-26-6 --description "…"
```

`publish` pushes the image, reads the digest the registry stored back, and
rewrites the catalog artifact users read. Note that a newly created ghcr package
is **private** — it has to be switched to public once, by hand, before anyone
else can pull it.

`phantom image build <name>` turns an IPSW into a ready-to-use, agent-installed
base image with one unattended command:

```
ipsw → vm.create (headless install) → Setup Assistant automation over VNC
     → agent install → provisioning over vsock → image.save
```

Setup Assistant is driven with no guest-side software: the daemon serves the
VM's framebuffer from the host via `_VZVNCServer` (a private API, invoked by
reflection) and a Swift VNC client injects keystrokes and clicks on-screen text
located with Vision.framework OCR. Once the agent is installed via VNC-typed
Terminal commands, all remaining provisioning runs through `vm.exec` over vsock —
no SSH. Provisioning scripts live in [provision/](provision/); the boot script is
per-macOS-version ([provision/setup-tahoe.txt](provision/setup-tahoe.txt) targets
Tahoe 26.x, creating a local admin `admin`/`admin` with passwordless sudo and
auto-login). Disk save/restore compress into 512 MB LZ4 chunks in parallel across
cores — a 24 GB VM saves in ~16s and restores in ~12s.

Supporting APIs/commands added along the way: `vm.vnc.start`/`stop`,
`vm.bootScript`/`.status`, `vm.screenshot`, and `phantom vm vnc | boot-script |
screenshot`.

## Roadmap

- [x] **Publish base image** — `xcode-26-6` is live at `ghcr.io/phantom-vm/xcode-26-6` (58.9GB, 138 layers). `image publish` pushes and rewrites a catalog artifact; `image list`/`image pull <name>` read it anonymously and pull by manifest digest. Verified from the outside: pulled with every credential source removed, all 138 layer digests matched the source image, and the VM it booted had Xcode 26.6 plus all four simulator runtimes.
- [ ] **`vm deploy --image` async** — fire-and-forget + status polling like `image.save`; also fixes a CLI-timeout race that can leave the bundle unregistered until a daemon restart. Low priority now that create is ~12s.
- [x] **Don't store all-zero chunks** — skipped at chunk time. 114 of `tahoe-base`'s 180 chunks were all-zero, so this removes ~63% of an image's layers (registry objects, push/pull round trips) though only ~1.4% of its bytes. Layers now carry a `chunk-index` annotation, since position no longer implies offset.
- [ ] **GitLab: registry-backed base image** — let the job's `image:` reference a registry image (e.g. `registry.gitlab.com/org/macos-ci:latest`) and auto-pull before `vm.create`.

Notes: `_VZVNCServer` is a private API (tart has shipped it for years); Setup
Assistant wording differs across macOS versions, so boot scripts are per-version.
