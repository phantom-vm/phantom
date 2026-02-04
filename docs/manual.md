# Creating a Ready-to-Use Phantom VM

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

## Step 5: Build the guest agent
On the **host** machine:
```bash
cd phantom-agent
swift build -c release
cp .build/release/phantom-agent ~/Library/Application\ Support/phantom/shared/
```

## Step 6: Install the guest agent
Inside the **guest VM**:
```bash
# The shared directory is auto-mounted
sudo cp "/Volumes/My Shared Files/phantom-agent" /usr/local/bin/
sudo chmod +x /usr/local/bin/phantom-agent
```

## Step 7: Run the guest agent
Inside the **guest VM**:
```bash
phantom-agent
```
You should see: `phantom-agent: listening for connections...`

## Step 8: Test host-to-guest execution
Back in the **host app**:
1. Type a command in the **"Run Command"** text field (e.g. `whoami`)
2. Click **Run**
3. You should see the output from inside the VM

## Optional: Auto-start the agent on boot
Inside the **guest VM**, create a launchd plist:
```bash
sudo tee /Library/LaunchDaemons/com.phantom.agent.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.phantom.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/phantom-agent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

sudo launchctl load /Library/LaunchDaemons/com.phantom.agent.plist
```

## Subsequent starts
Once the VM is installed, just click **"Start VM"** — no reinstall needed.
