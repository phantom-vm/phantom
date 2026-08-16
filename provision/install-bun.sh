#!/bin/sh
# Phantom image provisioning — installs the bun runtime into the guest as root
# (via the phantom-agent over vsock).
#
# macOS ships no JavaScript runtime, so anything a build step or a CI job wants
# to do in TypeScript starts with 90MB of download. Baking bun into the image
# pays that once, at build time, instead of in every job — and it is what lets a
# recipe step be a `.ts` file rather than shell, which is where the logic worth
# writing in a real language belongs.
#
#   BUN_VERSION=1.3.14 sh install-bun.sh
#
# Installed to /usr/local/bin rather than through bun.sh's installer, which
# unpacks into the *invoking user's* ~/.bun — and this runs as root, so the
# admin user CI jobs run as would never see it. The version is pinned here for
# the same reason the runner's is: an image should say what is in it.
set -e

VERSION="${1:-${BUN_VERSION:-1.3.14}}"
DEST=/usr/local/bin/bun
URL="https://github.com/oven-sh/bun/releases/download/bun-v$VERSION/bun-darwin-aarch64.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading bun $VERSION..."
mkdir -p /usr/local/bin
# A guest that has only just booted may not have finished DHCP, so the first
# connect can fail outright; --retry-connrefused waits that out.
curl -fL --retry 10 --retry-delay 5 --retry-connrefused --retry-all-errors \
  --connect-timeout 10 -o "$TMP/bun.zip" "$URL"

# Downloaded by curl, so it carries a quarantine xattr that would make the first
# exec prompt — which nothing can answer in a headless guest.
unzip -q "$TMP/bun.zip" -d "$TMP"
xattr -c "$TMP/bun-darwin-aarch64/bun" 2>/dev/null || true
chmod 755 "$TMP/bun-darwin-aarch64/bun"
chown root:wheel "$TMP/bun-darwin-aarch64/bun"
# Moved into place last, so an interrupted download never leaves a half-written
# binary on PATH for a job to trip over.
mv "$TMP/bun-darwin-aarch64/bun" "$DEST"

"$DEST" --version
