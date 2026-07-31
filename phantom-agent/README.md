# phantom-agent

Guest agent that runs inside the macOS VM to enable host-to-guest command execution via vsock.

## Installation in VM

Fresh VMs install the agent by fetching the published installer — a release
asset that downloads the binary, verifies it against a SHA-256 pinned at
release time, and loads the launchd daemon. Inside the guest:

```bash
curl -fsSL https://github.com/phantom-vm/phantom/releases/latest/download/phantom-agent-install.sh \
  -o /tmp/phantom-agent-install.sh
sudo sh /tmp/phantom-agent-install.sh
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
./make-install-script.sh .build/release/phantom-agent <url-you-will-serve-the-binary-at> > phantom-agent-install.sh
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
  B64=$(base64 -i .build/release/phantom-agent | tr -d '\n')

  phantom vm exec <vm-id> -- printf %s "$B64" '|' base64 -d '>' /tmp/phantom-agent \
    '&&' shasum -a 256 /tmp/phantom-agent
  phantom vm exec <vm-id> -- install -m 755 /tmp/phantom-agent /usr/local/bin/phantom-agent \
    '&&' pkill -x phantom-agent
  ```

  Two details this depends on, both easy to get wrong:

  - **Don't wrap it in `sh -c`.** `vm exec` joins everything after `--` into one
    command string, the way `ssh host cmd` does, and the guest agent runs that
    through `/bin/sh -c` itself. A nested `sh -c "…"` loses the grouping and the
    guest ends up running the first word with the rest as `$0`, `$1`, … The
    shell operators are quoted so the *host* shell passes them through.
  - **One line of base64, and quoted.** `$(base64 -i …)` unquoted is split on
    the wrapping newlines, and `echo` then prints something `base64 -d` cannot
    read. `tr -d '\n'` and the quotes are what make it arrive intact — check
    the `shasum` against the local file before installing.

- **Fresh image build** — serve the binary and the generated installer over
  HTTP on the vmnet bridge (the guest reaches the host at the bridge address,
  usually `192.168.64.1`), then point the build at it:

  ```bash
  mkdir -p /tmp/agent-serve
  cp .build/release/phantom-agent /tmp/agent-serve/
  ./make-install-script.sh /tmp/agent-serve/phantom-agent \
    http://192.168.64.1:8642/phantom-agent > /tmp/agent-serve/phantom-agent-install.sh
  python3 -m http.server 8642 --directory /tmp/agent-serve &

  phantom image build my-base --agent-url http://192.168.64.1:8642/phantom-agent-install.sh
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
