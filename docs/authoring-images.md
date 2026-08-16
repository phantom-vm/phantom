# Authoring and Publishing Images

For whoever produces the images everyone else pulls. Users don't need any of
this — they run `phantom image pull <name>`.

`ipsw`, `image build`, `image build-base`, `image publish` and `vm boot-script`
are hidden unless
`PHANTOM_ADMIN_MODE` is set:

```bash
export PHANTOM_ADMIN_MODE=1
```

Without it they are absent from `phantom help` and refuse to run, naming the
variable. That is decluttering, not access control — the commands are in every
binary, and each one only asks the local daemon for something it would do for
any caller. Don't treat the variable as a permission boundary.

## The whole pipeline

Run from the repo root, so `image build-base`'s default script paths under
[provision/](../provision/) resolve (a recipe's paths resolve against the recipe
itself, so `image build` works from anywhere):

```bash
phantom ipsw list                                   # catalog of macOS restore images
phantom ipsw pull 26.3                              # ~14GB from Apple's CDN

phantom image build-base tahoe-base
phantom image build -f recipes/xcode-26-6.yaml
phantom image publish xcode-26-6 --description "macOS 26 + Xcode 26.6 + all simulator runtimes"
```

Three steps, three different jobs:

| Command | What it does | Roughly |
|---|---|---|
| `image build-base <name>` | IPSW → installed, provisioned, agent-equipped base image | ~1 hour |
| `image build -f <recipe.yaml>` | Layers a toolchain onto a base image, as the recipe describes | Depends on the toolchain |
| `image publish <name>` | Pushes to the registry and rewrites the catalog users read | ~40 min for 55GB |

**The two builds are separate commands on purpose.** A base build happens once
per macOS release and is driven by flags; what goes *on top* is declared in a
recipe checked into [recipes/](../recipes/), because that is the part anyone
will need to read back later. Rebuilding an image in place — the cheap way to
add one thing — is a recipe whose `from:` is its own name, built with
`--replace`.

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

## Recipes

A layered image is a recipe: the base it starts from, and the steps that turn it
into something a CI job can run on.

```yaml
schema: 1
name: xcode-26-6
description: macOS 26 + Xcode 26.6 (17F113) + all simulator runtimes
from: tahoe-base

steps:
  - name: gitlab-runner
    script: ../provision/install-gitlab-runner.sh
    env:
      RUNNER_VERSION: v18.11.2
    timeout: 15m

  - name: xcode
    script: ../provision/install-xcode.sh
    env:
      XCODE_SRC: http://192.168.1.127:9001/xcodes/Xcode-26.6.0%2B17F113.xip
    timeout: 4h

  # The installer takes whatever XCODE_SRC points at, so only the recipe knows
  # which Xcode this image claims to be. grep exits non-zero on a mismatch.
  - name: verify
    run: xcodebuild -version | grep -q 'Xcode 26.6'
    timeout: 5m
```

| Key | Means |
|---|---|
| `schema` | `1`. Refused otherwise, rather than half-read |
| `name` | The image this produces — same rule as any image name |
| `from` | The base image to layer onto. Its own name, with `--replace`, rebuilds in place |
| `description` | Free text. Say what a reader would want to know a year from now |
| `steps[].name` | Names the step in the build output, and must be unique |
| `steps[].script` | A script file, sent as the command body. Paths resolve against the recipe's own directory |
| `steps[].run` | An inline command instead of a file. One of `script`/`run`, never both |
| `steps[].env` | Prepended as `KEY='value'` lines — how `XCODE_SRC` and `RUNNER_VERSION` reach their scripts |
| `steps[].serve` | A local file served to the guest over the vmnet bridge for this step. `${serve}` (in `env` or `run`) is its URL |
| `steps[].timeout` | `90s`, `15m`, `4h`. Default 30m |

Everything is checked before a VM is created — unknown keys included, since a
recipe that quietly ignores a typo is no longer an account of the image:

```bash
phantom image build -f recipes/xcode-26-6.yaml --dry-run
```

prints the resolved plan (which script, which env, which file served, how long
each step may take) and talks to no daemon at all.

Each step is one `vm.exec` over vsock, run as root in the guest, with its output
echoed as it arrives. A step that exits non-zero stops the build naming itself,
and the intermediate VM is left behind for inspection. That exit code is the
whole verdict — there is no "must print this" key, because a step that wants to
assert more is a step that greps for it, and the scripts already run under
`set -e`.

## gitlab-runner

`gitlab-runner` in the guest's `/usr/local/bin`
([provision/install-gitlab-runner.sh](../provision/install-gitlab-runner.sh)) is
a step like any other now — a recipe lists it or the image does not have it.
Every image CI runs on wants it: GitLab's custom executor runs a job's artifact
and cache stages *inside* the VM, and without the binary they are silently
skipped and `artifacts:` never uploads anything. Put it first, as
[recipes/xcode-26-6.yaml](../recipes/xcode-26-6.yaml) does — a 60MB download
that fails in seconds beats finding out after a three-hour Xcode install. Base
images don't have it: they are foundations to layer onto, not CI targets.

## Rebuilding an image in place

An image can be refreshed without redoing its toolchain, by layering it onto
itself — a recipe whose `from:` is its own `name:`, built with `--replace`:

```bash
phantom image build -f recipes/xcode-26-6-runner-bump.yaml --replace
```

`--replace` writes the new copy alongside the old one and swaps it in only when
it is complete, so a failed build leaves the old image where it was. Budget disk
for both at once, and note the replacement is a **local** image — it carries no
`pulled.json`, so `image catalog` marks it `(Downloaded)` and never `(update
available)`, however far the catalog moves ahead of it. Publishing does not
change that: `pulled.json` records where a *pull* came from, and the build host
never pulls its own image. To confirm a publish, read the digest `image publish`
prints back from the registry rather than the mark on the build host.

## Layering a toolchain

`from:` boots a VM from a finished image instead of installing macOS, so Setup
Assistant and provisioning are already done. The Xcode step installs from a
`.xip` named by `XCODE_SRC`. Apple requires a login to download Xcode, so the
URL is never a public one: [recipes/xcode-26-6.yaml](../recipes/xcode-26-6.yaml)
points at the build network's own file server and the guest fetches it itself,
with no 10GB detour through the host. Building somewhere without such a server,
`serve:` hands the guest a `.xip` sitting on this Mac instead, over an ephemeral
HTTP server on the vmnet bridge. Either way the URL or file name is where the
exact Xcode build is written down.
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
for a few minutes after it does. Until then `image catalog` simply omits the image
and `image pull <name>` says it could not reach the catalog.

**A description says what the image has, not what it lacks.** `image catalog` is a
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

Steps 2–7 are exactly what `phantom image build-base` does unattended.

## Related

- [design/images.md](design/images.md) — the image format, catalog schema, and why pulls pin digests
- [provision/README.md](../provision/README.md) — boot scripts and provisioning
