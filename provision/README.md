# Provisioning

Scripts for turning a fresh macOS install into a ready-to-use Phantom base
image, with no manual interaction.

## Flow

```
IPSW ─▶ vm.create (headless install) ─▶ setup-tahoe.txt (VNC) ─▶ provision.sh (vsock) ─▶ image.save
```

1. **Install** — `phantom vm deploy --ipsw <id>` installs macOS headlessly.
2. **Setup Assistant** — `phantom vm boot-script <vm-id> --file provision/setup-tahoe.txt`
   drives Setup Assistant over VNC (keystrokes + OCR clicks): creates a local
   admin account `admin`/`admin`, skips every online step, reaches the
   desktop, and installs the agent by fetching the published `phantom-agent-install.sh`
   release asset over the guest's NAT network (the installer checks the
   binary against a SHA-256 pinned at release time). After this the agent
   answers on vsock. For a dev agent, see `image build --agent-url` in
   [phantom-agent/README.md](../phantom-agent/README.md).
3. **Provision** — `phantom vm exec <vm-id> -- sh -c "$(cat provision/provision.sh)"`
   (or copy the script in) configures passwordless sudo, auto-login, and
   disables sleep / screensaver / screen lock — all over vsock.
4. **Save** — `phantom vm stop <vm-id>` then `phantom image save <vm-id> macos-tahoe-base`.

## Toolchain images

Toolchain images are layered onto a finished base image rather than built from
an IPSW again — macOS is already installed and provisioned there, so the build
is minutes of decompression instead of an hour of installing:

```
tahoe-base ─▶ vm.create --fromImage ─▶ install-xcode.sh (vsock) ─▶ image.save
```

```bash
phantom image build xcode-26-6 --image tahoe-base \
  --xcode http://192.168.1.127:9001/xcodes/Xcode-26.6.0%2B17F113.xip
```

The `--xcode` value is either a URL the guest can reach — downloaded inside the
guest, so 10GB never passes through the host — or a local `.xip` path, which
the CLI serves to the guest over an ephemeral HTTP server on the vmnet bridge
for the duration of the install. Apple's signature on the archive is checked by
`xip --expand`, which is also what makes the download safe to trust.

Every simulator runtime is downloaded too (`xcodebuild -downloadAllPlatforms`),
since Xcode ships with none — that is tens of GB once at build time instead of
several GB in every CI job. The build log ends with `simctl list runtimes` and
`simctl list devices available` so you can see which destinations the image can
test against.

## gitlab-runner in the guest

Every layered image `phantom image build --image` produces gets `gitlab-runner`
installed into `/usr/local/bin` (skip it with `--no-gitlab-runner`; base builds
skip it by default, `--gitlab-runner` forces it). GitLab's custom executor
runs *every* stage of a job inside the job environment, so a job declaring
`artifacts:` or `cache:` invokes `gitlab-runner artifacts-uploader` /
`cache-archiver` **inside the VM**. When the binary isn't there the stage prints

```
Missing gitlab-runner. Uploading artifacts is disabled.
```

and is skipped — the job still passes and the artifact never reaches GitLab.
Baking it in keeps that out of every project's `before_script`, and off the
network on every job.

The version is pinned in `install-gitlab-runner.sh`; `--gitlab-runner-version`
overrides it for one build. It does not have to match the host runner the daemon
manages — only the artifact/cache protocol has to line up — but keep the two
roughly in step.

To add it to an image that predates this, rebuild that image from itself:

```bash
phantom image build xcode-26-6 --image xcode-26-6 --replace
```

## Files

- **setup-tahoe.txt** — boot-script for macOS Tahoe (26.x) Setup Assistant.
  Screens are matched by on-screen text via OCR, so the script is resilient to
  layout shifts but tied to a macOS version's wording.
- **provision.sh** — post-install system configuration, run inside the guest as
  root through the agent.
- **install-gitlab-runner.sh** — puts the pinned `gitlab-runner` binary on the
  guest's PATH. Reads `RUNNER_VERSION` (or `$1`), defaulting to the pin in the
  script. See [gitlab-runner in the guest](#gitlab-runner-in-the-guest).
- **install-xcode.sh** — installs Xcode from a `.xip` into the guest, licenses
  it and runs first launch. Reads `XCODE_SRC` (or `$1`).

## Debugging boot scripts

`phantom vm screenshot <vm-id> --out screen.png` captures the current screen —
essential for authoring a script against a new macOS version, since Setup
Assistant wording and flow change between releases.

## Credentials

The base image ships with a well-known admin account **admin / admin** and
passwordless sudo. It is meant for ephemeral CI VMs on a trusted host, not for
exposure to untrusted networks.
