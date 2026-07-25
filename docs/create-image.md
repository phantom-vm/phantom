# Create a Ready-to-Use Phantom Image

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
phantom image save <vm-id> macos-sequoia-base
```

This image can be used directly as `PHANTOM_BASE_IMAGE` in the [GitLab runner integration](integration/gitlab.md).

## Step 9: Layer Xcode on top

The base image has no developer toolchain beyond the command line tools. Build a
Xcode image from it — this reuses the installed, provisioned macOS instead of
starting over from the IPSW:

```bash
phantom image build xcode-26-6 --image macos-sequoia-base \
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
