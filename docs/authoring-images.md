# Authoring and Publishing Images

For whoever produces the images everyone else pulls. Users don't need any of
this — they run `phantom image pull <name>`.

`ipsw`, `image build`, `image publish` and `vm boot-script` are hidden unless
`PHANTOM_ADMIN_MODE` is set:

```bash
export PHANTOM_ADMIN_MODE=1
```

Without it they are absent from `phantom help` and refuse to run, naming the
variable. That is decluttering, not access control — the commands are in every
binary, and each one only asks the local daemon for something it would do for
any caller. Don't treat the variable as a permission boundary.

## The whole pipeline

Run from the repo root, so the default script paths under [provision/](../provision/)
resolve:

```bash
phantom ipsw list                                   # catalog of macOS restore images
phantom ipsw pull 26.3                              # ~14GB from Apple's CDN

phantom image build tahoe-base
phantom image build xcode-26-6 --image tahoe-base --xcode <url-or-path-to-xip>
phantom image publish xcode-26-6 --description "macOS 26 + Xcode 26.6 + all simulator runtimes"
```

Three steps, three different jobs:

| Command | What it does | Roughly |
|---|---|---|
| `image build <name> --ipsw` | IPSW → installed, provisioned, agent-equipped base image | ~1 hour |
| `image build <name> --image <base>` | Layers a toolchain onto a finished image, skipping install and provisioning | Depends on the toolchain |
| `image build <name> --image <name> --replace` | Rebuilds an image in place — the cheap way to add one thing | Decompress + save |
| `image publish <name>` | Pushes to the registry and rewrites the catalog users read | ~40 min for 55GB |

## Building a base image

```
ipsw → vm.create (headless install) → Setup Assistant automation over VNC
     → agent install → provisioning over vsock → image.save
```

Setup Assistant is driven with no guest-side software: the daemon serves the VM's
framebuffer from the host via `_VZVNCServer` (a private API, invoked by
reflection) and a Swift VNC client injects keystrokes and clicks on-screen text
located with Vision.framework OCR. The agent is bootstrapped by one VNC-typed
Terminal command that fetches the published `phantom-agent-install.sh` release asset
over the guest's NAT network and runs it as root — the installer verifies the
binary against a SHA-256 pinned into it at release time. Everything after that
runs through `vm.exec` over vsock — no SSH. To build with an unreleased agent,
`--agent-url` points that fetch at a dev-served installer instead
([phantom-agent/README.md](../phantom-agent/README.md)).

The boot script is **per macOS version**, because Setup Assistant's wording
changes between releases: [provision/setup-tahoe.txt](../provision/setup-tahoe.txt)
targets Tahoe 26.x and creates a local admin `admin`/`admin` with passwordless
sudo and auto-login. Authoring one for a new release is the one case
where [doing it by hand](#doing-it-by-hand) earns its keep.
[provision/README.md](../provision/README.md) covers the scripts themselves.

## gitlab-runner

Layered (`--image`) builds install `gitlab-runner` into the guest's
`/usr/local/bin` ([provision/install-gitlab-runner.sh](../provision/install-gitlab-runner.sh)),
because GitLab's custom executor runs a job's artifact and cache stages *inside*
the VM — without the binary they are silently skipped and `artifacts:` never
uploads anything. Base builds from an IPSW skip it: they are foundations to
layer toolchains onto, not CI targets. `--gitlab-runner` forces it onto a base
build (do this if CI jobs will run on the base image directly),
`--no-gitlab-runner` skips it on a layered build, `--gitlab-runner-version <v>`
overrides the pin.

An image built before this can be refreshed without redoing its toolchain, by
layering it onto itself:

```bash
phantom image build xcode-26-6 --image xcode-26-6 --replace
```

`--replace` writes the new copy alongside the old one and swaps it in only when
it is complete, so a failed build leaves the old image where it was. Budget disk
for both at once, and note the replacement is a **local** image — it carries no
`pulled.json`, so `image list` reports it as origin unknown. Publishing does not
change that: `pulled.json` records where a *pull* came from, and the build host
never pulls its own image. On the machine that built it the mark stays until you
pull it back; verify a publish against the registry instead (see below).

## Layering a toolchain

`--image <name>` boots a VM from a finished image instead of installing macOS, so
Setup Assistant and provisioning are already done. `--xcode <url|path>` then
installs Xcode from a `.xip`: a URL is fetched by the guest itself (no 10GB
detour through the host), a local path is served to the guest over an ephemeral
HTTP server on the vmnet bridge.
`xip --expand` verifies Apple's signature on the archive, which doubles as the
integrity check. Every simulator runtime is downloaded too, since Xcode ships
with none and otherwise every CI job would pay for that.

## Publishing

```bash
docker login ghcr.io    # or set PHANTOM_REGISTRY_USERNAME / PHANTOM_REGISTRY_PASSWORD
phantom image publish xcode-26-6 --description "…"
```

`publish` pushes the image, reads back the digest the registry actually stored,
and writes that entry into `catalog.json`. The digest is read back rather than
computed locally because the daemon re-encodes the manifest when pushing, so
only the registry knows the bytes it kept.

**The catalog is a file in this repo, so publishing ends with a commit.** Run
`publish` from the checkout — it edits `./catalog.json` by default
(`--catalog-file` points it elsewhere) — then commit and push:

```bash
git add catalog.json && git commit -m "Publish xcode-26-6" && git push
```

Nothing resolves until that lands on `main`, and raw.githubusercontent caches
for a few minutes after it does. Until then `image list` simply omits the image
and `image pull <name>` says it could not reach the catalog.

**A description says what the image has, not what it lacks.** `image list` is a
menu, and an entry that spends its length on absences reads as a defect report
rather than a choice. Name the OS build and the toolchain, in that order:

```
macOS 26 + Xcode 26.6 (17F113) + all simulator runtimes
macOS 26.5.2 (25F84) + Command Line Tools — the base for layering your own toolchain
```

`--catalog-only` rewrites the entry without re-pushing blobs, so wording can be
fixed for the price of a catalog write rather than the image's whole size.

**A newly created ghcr package is private.** Switch both the image and the
`catalog` package to public once, by hand, in the package settings on GitHub —
until then anonymous pulls get a 403. Check rather than assume:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:phantom-vm/xcode-26-6:pull&service=ghcr.io' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/phantom-vm/xcode-26-6/manifests/latest      # expect 200
```

Credentials are resolved by the CLI and passed to the daemon in the request. That
direction matters: the daemon is a GUI app started by Launch Services, so it
inherits neither the shell environment nor access to a Keychain-backed
`docker login`.

## Doing it by hand

Only worth it to author a boot script for a macOS version that doesn't have one:
you need to watch each Setup Assistant screen to script it. `phantom vm screenshot
<vm-id> --out screen.png` shows what the script is looking at, and the screens are
matched by on-screen text via OCR, so a script survives layout shifts but not
changed wording.

1. **Run the daemon** — open `phantom.xcodeproj` in Xcode, build and run.
2. **Get an IPSW** — `phantom ipsw pull <version>`, or "Download Image" in the
   app (~14GB).
3. **Install macOS** — `phantom vm deploy --ipsw <id>`, or "Create & Start VM" in
   the app. Takes ~20 minutes; the display window opens when it's done.
4. **Walk through Setup Assistant** — `phantom vm vnc <vm-id>` (or "Show Display"),
   skip Apple ID, create a local admin account. This is the part being scripted,
   so note the exact wording of each screen.
5. **Install the agent** — in the guest's Terminal:

   ```bash
   curl -fsSL https://github.com/phantom-vm/phantom/releases/latest/download/phantom-agent-install.sh \
     -o /tmp/phantom-agent-install.sh
   sudo sh /tmp/phantom-agent-install.sh
   ```

   It downloads `/usr/local/bin/phantom-agent`, verifies its pinned SHA-256,
   and loads a launchd daemon (`com.monk.phantom-agent`) that starts on boot.
6. **Check vsock works** — `phantom vm exec <vm-id> -- whoami` should answer from
   inside the VM.
7. **Provision and save** — apply [provision/provision.sh](../provision/provision.sh),
   then `phantom vm stop <vm-id>` and `phantom image save <vm-id> <name>`.

Steps 2–7 are exactly what `phantom image build --ipsw` does unattended.

## Related

- [design/images.md](design/images.md) — the image format, catalog schema, and why pulls pin digests
- [provision/README.md](../provision/README.md) — boot scripts and provisioning
