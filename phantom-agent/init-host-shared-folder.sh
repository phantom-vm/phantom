#!/bin/bash
# Copy phantom-agent files to phantom/shared directory
# Run this on the host to make agent files available in VMs

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHANTOM_SHARED="$HOME/Library/Application Support/phantom/shared"

mkdir -p "$PHANTOM_SHARED"

# Build the binary
echo "Building phantom-agent..."
cd "$SCRIPT_DIR"
swift build -c release

# Copy binary and installation files
echo "Copying files to $PHANTOM_SHARED..."
cp "$SCRIPT_DIR/.build/release/phantom-agent" "$PHANTOM_SHARED/"
cp "$SCRIPT_DIR/install.sh" "$PHANTOM_SHARED/"
cp "$SCRIPT_DIR/uninstall.sh" "$PHANTOM_SHARED/"
cp "$SCRIPT_DIR/com.monk.phantom-agent.plist" "$PHANTOM_SHARED/"

echo ""
echo "✓ Built and copied phantom-agent to phantom/shared"
echo ""
echo "Next steps (inside macOS VM):"
echo "  1. Mount shared: sudo mount_virtiofs phantom-shared /Volumes/phantom-shared"
echo "  2. Run install: cd /Volumes/phantom-shared && ./install.sh"
