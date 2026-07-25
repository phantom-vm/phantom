# Create an Image by Hand

`phantom image build` automates all of this ([authoring-images.md](authoring-images.md)),
so the only reason to work through it manually is to author a boot script for a
macOS version that doesn't have one yet — you need to see each Setup Assistant
screen to script it.

## Step 1: Build the host app
1. Open `phantom.xcodeproj` in Xcode
2. Build & run the Phantom app

## Step 2: Download macOS image
1. Click **"Download Image"** in the app
2. Wait for the IPSW download to complete (~14GB)

## Step 3: Create & install VM
1. Click **"Create & Start VM"**
2. Wait for macOS installation to complete (watch progress bar)
3. The VM display window opens automatically when done

## Step 4: Complete macOS setup
1. Click **"Show Display"** to open the VM window
2. Walk through the macOS setup assistant (language, account, etc.)
3. Skip Apple ID, create a local user account

## Step 5: Build and stage the guest agent
On the **host** machine:
```bash
cd phantom-agent
./init-host-shared-folder.sh
```

This builds `phantom-agent` and copies it along with the install scripts into the phantom shared directory, making them available inside any running VM.

## Step 6: Install the guest agent
Inside the **guest VM**:
```bash
# Mount the shared directory
sudo mkdir -p /Volumes/phantom-shared
sudo mount_virtiofs phantom-shared /Volumes/phantom-shared

# Run the installer
cd /Volumes/phantom-shared && sudo ./install.sh
```

The installer copies the binary to `/usr/local/bin/phantom-agent` and registers it as a launchd daemon (`com.monk.phantom-agent`) that starts automatically on boot.

## Step 7: Test host-to-guest execution
On the **host** machine, get the VM ID and run a test command:
```bash
phantom vm list
phantom vm exec <vm-id> -- whoami
```

You should see the output from inside the VM.

## Step 8: Save as image
Stop the VM, then save it as a named local image for use as a CI base:
```bash
phantom vm stop <vm-id>
phantom image save <vm-id> tahoe-base
```

This image is what a toolchain image is layered onto (step 9), and can be named directly in a job's `image:` for the [GitLab runner integration](integration/gitlab.md).

## Step 9: Layer Xcode on top

The base image has no developer toolchain beyond the command line tools. Build a
Xcode image from it — this reuses the installed, provisioned macOS instead of
starting over from the IPSW:

```bash
phantom image build xcode-26-6 --image tahoe-base \
  --xcode http://192.168.1.127:9001/xcodes/Xcode-26.6.0%2B17F113.xip
```

`--xcode` also accepts a local `.xip` path, which is staged through the shared
folder instead of being fetched by the guest. Every simulator runtime is
installed as part of this step, so the image can run iOS/watchOS/tvOS tests as
well as macOS ones. Verify the result by starting a VM from the image and
building something in it:

```bash
phantom vm deploy --image xcode-26-6
phantom vm exec <vm-id> -- xcodebuild -version
```

Note that steps 1–8 above are what `phantom image build <name> --ipsw <id>`
automates end to end; doing them by hand is only useful when authoring a new
boot script.

## Step 10: Publish it

Users never run any of the above — they pull. Publishing pushes the image and
lists it in the catalog `phantom image list` reads:

```bash
docker login ghcr.io     # credentials also picked up from PHANTOM_REGISTRY_USERNAME/PASSWORD
phantom image publish xcode-26-6 --description "macOS 26 + Xcode 26.6 + all simulator runtimes"
```

A newly created ghcr package is **private**, so this one-time step is needed
before anyone else can pull: open the package's settings on GitHub and change
its visibility to public — for both the image and the `catalog` package. Until
then anonymous requests get a 403, which is worth checking rather than assuming:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:phantom-vm/xcode-26-6:pull&service=ghcr.io' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/phantom-vm/xcode-26-6/manifests/latest      # expect 200
```

Afterwards any machine can `phantom image pull xcode-26-6`, which resolves the
name through the catalog and pulls by manifest digest. See the Image Catalog
section of [DESIGN.md](../DESIGN.md) for the format and why it pins digests.
