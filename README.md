# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Documentation

- [Create a Ready-to-Use Phantom Image](docs/create-image.md) — set up a base VM with phantom-agent installed and save it as an image
- [GitLab CI Integration](docs/integration/gitlab.md) — use Phantom as a GitLab custom executor for ephemeral macOS CI jobs

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Usage

Build a base image from a downloaded IPSW — one unattended command (run from the repo root so it finds `provision/`; image-authoring commands like `ipsw` and `image build` only exist in the admin CLI build, `bun run install-bin` — the user build from `bun run build-user-bin` omits them, since regular users start from a published base image):

```
phantom image build macos-tahoe --agent-dir phantom-agent
```

Deploy a VM and run commands in it over vsock:

```
phantom vm deploy --image macos-tahoe                   # boot a VM from the image
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

Turn the Mac into a GitLab CI runner (auto-downloads and manages `gitlab-runner`, each job runs in a fresh VM):

```
phantom gitlab-runner setup --token glrt-xxx    # jobs pick their VM via 'image: <name>'
```

## Automated Image Building

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

- [ ] **Publish base image** — push the built base image to a registry so users only ever `image pull` (the build pipeline is done; `push` wiring remains).
- [ ] **`vm deploy --image` async** — fire-and-forget + status polling like `image.save`; also fixes a CLI-timeout race that can leave the bundle unregistered until a daemon restart. Low priority now that create is ~12s.
- [ ] **Don't store all-zero chunks** — skip them at chunk time to shrink images (restore already skips writing zeros).
- [ ] **GitLab: registry-backed base image** — let the job's `image:` reference a registry image (e.g. `registry.gitlab.com/org/macos-ci:latest`) and auto-pull before `vm.create`.

Notes: `_VZVNCServer` is a private API (tart has shipped it for years); Setup
Assistant wording differs across macOS versions, so boot scripts are per-version.
