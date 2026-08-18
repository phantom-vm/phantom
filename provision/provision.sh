#!/bin/sh
# Phantom base-image provisioning — runs inside the guest as root (via the
# phantom-agent over vsock) once Setup Assistant is done and the agent is
# installed. Prepares a hands-off CI-friendly macOS: passwordless sudo, auto
# login, no sleep / screensaver / screen lock, the command line tools, and mise
# for everything a later image or a job installs.
#
#   phantom vm exec <vm-id> -- sh -c "$(cat provision/provision.sh)"
#
# Assumes an admin account "admin" with password "admin".
set -e

USER_NAME=admin
USER_PASS=admin
# Pinned, like every other version this image bakes in: an image should be able
# to say what is in it. MISE_VERSION= overrides it for one build.
MISE_VERSION="${MISE_VERSION:-v2026.8.6}"

echo "Enabling passwordless sudo for $USER_NAME..."
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin-nopasswd
chmod 440 /etc/sudoers.d/admin-nopasswd

echo "Enabling auto-login for $USER_NAME..."
# /etc/kcpassword is the login password XOR'd with Apple's fixed key.
# 1ced3f4abcbcba2ccaca4e82 is "admin" encoded; see xfreebird/kcpassword.
echo 1ced3f4abcbcba2ccaca4e82 | xxd -r -p - /etc/kcpassword
chmod 600 /etc/kcpassword
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$USER_NAME"

echo "Disabling sleep..."
systemsetup -setsleep Off 2>/dev/null || true
pmset -a sleep 0 displaysleep 0 2>/dev/null || true

echo "Disabling screensaver and screen lock..."
defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
sysadminctl -screenLock off -password "$USER_PASS" 2>/dev/null || true

echo "Installing mise $MISE_VERSION as $USER_NAME..."
# The tool manager every later image and every CI job gets its runtimes from.
# It belongs in the base rather than in a recipe because it is not a toolchain —
# it is how toolchains arrive, and a layered image asking for bun should not
# first have to arrange for something to install bun with.
#
# Installed as the admin user, the way mise documents it and the way a person
# would: this script runs as root, and mise keeps its tools under the invoking
# user's home. Installed by root they would live in /var/root (mode 0700) —
# invisible to the admin user CI jobs actually run as.
# The version goes to the *installer*, not to curl: it is the script on the
# right of the pipe that reads MISE_VERSION, and putting the assignment on the
# left set it for the download instead — which is how a pinned build quietly
# installed whatever was newest.
su - "$USER_NAME" -c "curl -fsSL https://mise.run | MISE_VERSION='$MISE_VERSION' sh"

# Two shell files, because the two ways into this guest read different ones:
#
#   ~/.zshrc   — an interactive terminal, where `mise activate` is what mise
#                recommends: it puts the tools of the current directory's config
#                on PATH and keeps up as you cd around.
#   ~/.zshenv  — every zsh, interactive or not, which is the only one that
#                reaches `su - admin -c '<command>'`: a non-interactive login
#                shell never reads .zshrc, and that is exactly how vm.exec and
#                every CI job stage arrive. Hence the shims directory, which is
#                what mise itself points CI and scripts at.
su - "$USER_NAME" -c 'grep -q "mise activate" ~/.zshrc 2>/dev/null || echo "eval \"\$(~/.local/bin/mise activate zsh)\"" >> ~/.zshrc'
su - "$USER_NAME" -c 'grep -q "mise/shims" ~/.zshenv 2>/dev/null || echo "export PATH=\"\$HOME/.local/share/mise/shims:\$HOME/.local/bin:\$PATH\"" >> ~/.zshenv'

su - "$USER_NAME" -c "mise --version"

echo "Installing Xcode Command Line Tools (needed for git in CI)..."
# Headless CLT install: the marker file makes softwareupdate list CLT packages
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
CLT_LABEL=$(softwareupdate -l 2>/dev/null | sed -n 's/^.*Label: \(Command Line Tools for Xcode.*\)$/\1/p' | sort | tail -1)
[ -n "$CLT_LABEL" ] || { echo "No CLT package found in softwareupdate catalog"; exit 1; }
echo "Installing: $CLT_LABEL"
softwareupdate -i "$CLT_LABEL"
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
git --version

echo "PROVISION_DONE"
