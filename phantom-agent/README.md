# phantom-agent

Guest agent that runs inside the macOS VM to enable host-to-guest command execution via vsock.

## Installation in VM

Fresh VMs install the agent by fetching the published installer — a release
asset that downloads the binary, verifies it against a SHA-256 pinned at
release time, and loads the launchd daemon. Inside the guest:

```bash
curl -fsSL https://github.com/phantom-vm/phantom/releases/latest/download/agent-install.sh \
  -o /tmp/agent-install.sh
sudo sh /tmp/agent-install.sh
```

This is exactly what `provision/setup-tahoe.txt` types into the guest during
`image build`. It installs:
- Binary to `/usr/local/bin/phantom-agent`
- launchd daemon plist to `/Library/LaunchDaemons/`
- Loads and starts the daemon

### Verify

```bash
# Check if daemon is running
sudo launchctl list | grep phantom-agent

# View logs
sudo tail -f /var/log/phantom-agent.out.log
sudo tail -f /var/log/phantom-agent.err.log
```

## Developing the agent

Iterating on the agent must not require cutting a release, so everything the
release publishes can be generated locally:

```bash
swift build -c release
./make-install-script.sh .build/release/phantom-agent <url-you-will-serve-the-binary-at> > agent-install.sh
```

To get a dev build into a VM:

- **VM with a working agent** — skip the installer machinery entirely; carry
  the binary in over vsock, base64-encoded inside the command string (the same
  trick the GitLab executor uses for job scripts), swap it, and kill the
  daemon — launchd's `KeepAlive` restarts it with the new binary. The kill
  also takes down the shell running the command, so the exec reports a
  failure; that's expected. Don't `launchctl unload` here: it removes the job
  and kills the shell before it can `load` again, leaving no agent at all.

  ```bash
  phantom vm exec <vm-id> -- sh -c "echo $(base64 -i .build/release/phantom-agent) \
    | base64 -d > /tmp/phantom-agent \
    && sudo install -m 755 /tmp/phantom-agent /usr/local/bin/phantom-agent \
    && sudo pkill -x phantom-agent"
  ```

- **Fresh image build** — serve the binary and the generated installer over
  HTTP on the vmnet bridge (the guest reaches the host at the bridge address,
  usually `192.168.64.1`), then point the build at it:

  ```bash
  mkdir -p /tmp/agent-serve
  cp .build/release/phantom-agent /tmp/agent-serve/
  ./make-install-script.sh /tmp/agent-serve/phantom-agent \
    http://192.168.64.1:8642/phantom-agent > /tmp/agent-serve/agent-install.sh
  python3 -m http.server 8642 --directory /tmp/agent-serve &

  phantom image build my-base --agent-url http://192.168.64.1:8642/agent-install.sh
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
