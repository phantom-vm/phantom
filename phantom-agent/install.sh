#!/bin/bash
# Install phantom-agent as a launchd daemon in the VM
# Run this script inside the macOS VM

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy binary to system location
echo "Installing binary to /usr/local/bin..."
sudo mkdir -p /usr/local/bin
sudo cp "$SCRIPT_DIR/phantom-agent" /usr/local/bin/phantom-agent
sudo chmod +x /usr/local/bin/phantom-agent

# Install launchd plist
echo "Installing launchd daemon..."
sudo cp "$SCRIPT_DIR/com.monk.phantom-agent.plist" /Library/LaunchDaemons/
sudo chmod 644 /Library/LaunchDaemons/com.monk.phantom-agent.plist

# Load and start the daemon
echo "Starting phantom-agent daemon..."
sudo launchctl load /Library/LaunchDaemons/com.monk.phantom-agent.plist

echo "✓ phantom-agent installed and started"
echo "  View logs: sudo tail -f /var/log/phantom-agent.*.log"
echo "  Stop: sudo launchctl unload /Library/LaunchDaemons/com.monk.phantom-agent.plist"
echo "  Start: sudo launchctl load /Library/LaunchDaemons/com.monk.phantom-agent.plist"
