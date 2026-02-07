#!/bin/bash
# Uninstall phantom-agent launchd daemon
# Run this script inside the macOS VM

set -e

# Unload daemon
echo "Stopping phantom-agent daemon..."
sudo launchctl unload /Library/LaunchDaemons/com.monk.phantom-agent.plist 2>/dev/null || true

# Remove files
echo "Removing files..."
sudo rm -f /Library/LaunchDaemons/com.monk.phantom-agent.plist
sudo rm -f /usr/local/bin/phantom-agent
sudo rm -f /var/log/phantom-agent.*.log

echo "✓ phantom-agent uninstalled"
