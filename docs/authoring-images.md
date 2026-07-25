# Authoring and Publishing Images

For whoever produces the images everyone else pulls. Users don't need any of
this — they run `phantom image pull <name>`.

These commands exist only in the **admin** CLI build (`bun run install-bin`); the
user build (`bun run build-user-bin`) omits `ipsw`, `image build`, and
`image publish` entirely, so the code behind them isn't shipped to users.

## The whole pipeline

Run from the repo root, so the default script paths under [provision/](../provision/)
resolve:

```bash
phantom ipsw list                                   # catalog of macOS restore images
phantom ipsw pull 26.3                              # ~14GB from Apple's CDN

phantom image build tahoe-base --agent-dir phantom-agent
phantom image build xcode-26-6 --image tahoe-base --xcode <url-or-path-to-xip>
phantom image publish xcode-26-6 --description "macOS 26 + Xcode 26.6 + all simulator runtimes"
```

Three steps, three different jobs:

| Command | What it does | Roughly |
|---|---|---|
| `image build <name> --ipsw` | IPSW → installed, provisioned, agent-equipped base image | ~1 hour |
| `image build <name> --image <base>` | Layers a toolchain onto a finished image, skipping install and provisioning | Depends on the toolchain |
| `image publish <name>` | Pushes to the registry and rewrites the catalog users read | ~40 min for 55GB |

## Building a base image

```
ipsw → vm.create (headless install) → Setup Assistant automation over VNC
     → agent install → provisioning over vsock → image.save
```

Setup Assistant is driven with no guest-side software: the daemon serves the VM's
framebuffer from the host via `_VZVNCServer` (a private API, invoked by
reflection) and a Swift VNC client injects keystrokes and clicks on-screen text
located with Vision.framework OCR. Once the agent is installed by VNC-typed
Terminal commands, everything after that runs through `vm.exec` over vsock — no
SSH.

The boot script is **per macOS version**, because Setup Assistant's wording
changes between releases: [provision/setup-tahoe.txt](../provision/setup-tahoe.txt)
targets Tahoe 26.x and creates a local admin `admin`/`admin` with passwordless
sudo and auto-login. Authoring one for a new release is the one case where the
by-hand walkthrough in [create-image.md](create-image.md) earns its keep —
`phantom vm screenshot <vm-id> --out screen.png` is how you see what the script
is looking at. [provision/README.md](../provision/README.md) covers the scripts
themselves.

## Layering a toolchain

`--image <name>` boots a VM from a finished image instead of installing macOS, so
Setup Assistant and provisioning are already done. `--xcode <url|path>` then
installs Xcode from a `.xip`: a URL is fetched by the guest itself (no 10GB
detour through the host), a local path is staged through the shared folder.
`xip --expand` verifies Apple's signature on the archive, which doubles as the
integrity check. Every simulator runtime is downloaded too, since Xcode ships
with none and otherwise every CI job would pay for that.

## Publishing

```bash
docker login ghcr.io    # or set PHANTOM_REGISTRY_USERNAME / PHANTOM_REGISTRY_PASSWORD
phantom image publish xcode-26-6 --description "…"
```

`publish` pushes the image, reads back the digest the registry actually stored,
and rewrites the catalog artifact that `phantom image list` reads. The digest is
read back rather than computed locally because the daemon re-encodes the manifest
when pushing, so only the registry knows the bytes it kept.

**A newly created ghcr package is private.** Switch both the image and the
`catalog` package to public once, by hand, in the package settings on GitHub —
until then anonymous pulls get a 403. Worth verifying rather than assuming; see
[create-image.md](create-image.md#step-10-publish-it) for a one-liner that checks
it.

Credentials are resolved by the CLI and passed to the daemon in the request. That
direction matters: the daemon is a GUI app started by Launch Services, so it
inherits neither the shell environment nor access to a Keychain-backed
`docker login`.

## Related

- [DESIGN.md](../DESIGN.md) — the image format, catalog schema, and why pulls pin digests
- [create-image.md](create-image.md) — the same pipeline by hand, for authoring a new boot script
- [provision/README.md](../provision/README.md) — boot scripts and provisioning
