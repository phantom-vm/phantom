# Provisioning

Scripts for turning a fresh macOS install into a ready-to-use Phantom base
image, with no manual interaction.

## Flow

```
IPSW ─▶ vm.create (headless install) ─▶ setup-tahoe.txt (VNC) ─▶ provision.sh (vsock) ─▶ image.save
```

1. **Install** — `phantom vm deploy --ipsw <id>` installs macOS headlessly.
2. **Stage the agent** — `cd phantom-agent && ./init-host-shared-folder.sh`
   builds `phantom-agent` and copies it into the shared folder.
3. **Setup Assistant** — `phantom vm boot-script <vm-id> --file provision/setup-tahoe.txt`
   drives Setup Assistant over VNC (keystrokes + OCR clicks): creates a local
   admin account `admin`/`admin`, skips every online step, reaches the
   desktop, and installs the agent. After this the agent answers on vsock.
4. **Provision** — `phantom vm exec <vm-id> -- sh -c "$(cat provision/provision.sh)"`
   (or copy the script in) configures passwordless sudo, auto-login, and
   disables sleep / screensaver / screen lock — all over vsock.
5. **Save** — `phantom vm stop <vm-id>` then `phantom image save <vm-id> macos-tahoe-base`.

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
guest, so 10GB never passes through the shared folder — or a local `.xip` path,
which is copied into the shared folder and read from `/Volumes/phantom-shared`.
Apple's signature on the archive is checked by `xip --expand`, which is also
what makes the download safe to trust.

Every simulator runtime is downloaded too (`xcodebuild -downloadAllPlatforms`),
since Xcode ships with none — that is tens of GB once at build time instead of
several GB in every CI job. The build log ends with `simctl list runtimes` and
`simctl list devices available` so you can see which destinations the image can
test against.

## Files

- **setup-tahoe.txt** — boot-script for macOS Tahoe (26.x) Setup Assistant.
  Screens are matched by on-screen text via OCR, so the script is resilient to
  layout shifts but tied to a macOS version's wording.
- **provision.sh** — post-install system configuration, run inside the guest as
  root through the agent.
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
