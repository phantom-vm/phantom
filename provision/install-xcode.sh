#!/bin/sh
# Phantom image provisioning — installs Xcode into the guest as root (via the
# phantom-agent over vsock), after provision.sh has run and the desktop is up.
#
# The .xip is named by XCODE_SRC (or $1), either an http(s) URL the guest can
# reach or a path already visible inside the guest. A URL is downloaded
# straight into the guest — `image build --xcode <local path>` serves the file
# to the guest over an ephemeral HTTP server on the host for exactly this.
#
#   XCODE_SRC=http://host:9001/xcodes/Xcode-26.6.0+17F113.xip sh install-xcode.sh
#
# Xcode 26 ships with no simulator runtimes, so every one of them is downloaded
# here — an image that has to run simulator tests would otherwise make each CI
# job fetch several GB before it could start.
#
# Expects ~60GB free: ~10GB for the .xip, ~35GB for the expanded app and the
# rest for the runtimes. The .xip is deleted the moment expansion succeeds, so
# first launch and the runtime downloads get that space back.
set -e

# Runs as admin (what a CI job is) or as root, and does the same thing either
# way: the privileged lines say so, rather than the whole script assuming a
# privilege it mostly does not need. admin's sudo is passwordless, arranged by
# provision.sh.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

SRC="${1:-$XCODE_SRC}"
[ -n "$SRC" ] || { echo "usage: XCODE_SRC=<url-or-path> sh install-xcode.sh"; exit 1; }

WORK=/tmp/phantom-xcode
APP=/Applications/Xcode.app

df -g / | tail -1 | awk '{print "Free space on /: " $4 "GB"}'

rm -rf "$WORK"
mkdir -p "$WORK"

case "$SRC" in
  http://*|https://*)
    XIP="$WORK/Xcode.xip"
    echo "Downloading $SRC..."
    # A guest that has only just booted may not have finished DHCP, so the first
    # connect can fail outright; --retry-connrefused waits that out, and the
    # other retries survive a flaky LAN mid-download.
    curl -fL --retry 10 --retry-delay 5 --retry-connrefused --retry-all-errors \
      --connect-timeout 10 -o "$XIP" "$SRC"
    ;;
  *)
    XIP="$SRC"
    [ -f "$XIP" ] || { echo "Not found in guest: $XIP"; exit 1; }
    echo "Using guest-local .xip $XIP"
    ;;
esac

ls -lh "$XIP" | awk '{print "Archive size: " $5}'

# xip --expand verifies Apple's signature on the archive and refuses to expand
# anything tampered with, which doubles as our integrity check on the download.
echo "Expanding (this takes a while)..."
cd "$WORK"
xip --expand "$XIP"

EXPANDED=$(find "$WORK" -maxdepth 1 -name "Xcode*.app" | head -1)
[ -n "$EXPANDED" ] || { echo "No Xcode*.app after expansion"; exit 1; }

# Free the 10GB archive before first launch needs room for its packages.
case "$SRC" in http://*|https://*) rm -f "$XIP" ;; esac

echo "Installing to $APP..."
$SUDO rm -rf "$APP"
# Same volume as /tmp, so this is a rename rather than a 35GB copy.
$SUDO mv "$EXPANDED" "$APP"
$SUDO chown -R root:wheel "$APP"
rm -rf "$WORK"

echo "Selecting toolchain..."
$SUDO xcode-select -s "$APP/Contents/Developer"

echo "Accepting license..."
$SUDO xcodebuild -license accept

echo "Running first launch (installs bundled packages)..."
$SUDO xcodebuild -runFirstLaunch

# Lets the admin account build and debug without an authorization prompt —
# there is nobody to click it in a headless CI VM.
$SUDO DevToolsSecurity -enable 2>/dev/null || true

# Not sudo: the runtimes belong to the user that will run the simulators, and
# CoreSimulator seeds its device set per user.
echo "Downloading simulator runtimes for every platform..."
xcodebuild -downloadAllPlatforms

xcodebuild -version
xcrun --find clang
xcrun simctl list runtimes
# CoreSimulator seeds a default device set per installed runtime; print it so the
# build log shows which destinations the image can actually test against.
xcrun simctl list devices available
echo "XCODE_INSTALL_DONE"
