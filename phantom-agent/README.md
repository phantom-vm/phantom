# phantom-agent

Guest agent that runs inside the macOS VM to enable host-to-guest command execution via vsock.

## Installation in VM

### 1. Build and copy to shared directory (on host)

```bash
cd phantom-agent
./init-host-shared-folder.sh
```

This builds the phantom-agent binary and copies it along with installation scripts to the shared directory.

### 2. Mount shared directory and install (inside VM)

```bash
# Create mount point
sudo mkdir -p /Volumes/phantom-shared

# Mount the VirtioFS share (tag: phantom-shared)
sudo mount_virtiofs phantom-shared /Volumes/phantom-shared

# Run installation
cd /Volumes/phantom-shared
./install.sh
```

This will:
- Install binary to `/usr/local/bin/phantom-agent`
- Install launchd daemon plist to `/Library/LaunchDaemons/`
- Load and start the daemon

### 3. Verify

```bash
# Check if daemon is running
sudo launchctl list | grep phantom-agent

# View logs
sudo tail -f /var/log/phantom-agent.out.log
sudo tail -f /var/log/phantom-agent.err.log
```

## Management

**Restart:**
```bash
sudo launchctl unload /Library/LaunchDaemons/com.monk.phantom-agent.plist
sudo launchctl load /Library/LaunchDaemons/com.monk.phantom-agent.plist
```

**Uninstall:**
```bash
./uninstall.sh
```

## How it works

- Listens on vsock port 9001
- Accepts newline-delimited JSON commands: `{"command": "...", "args": [...]}`
- Executes via `/bin/sh -c`
- Returns JSON response: `{"stdout": "...", "stderr": "...", "exitCode": 0}`
- Auto-starts on VM boot via launchd
- Restarts automatically if it crashes (KeepAlive=true)
