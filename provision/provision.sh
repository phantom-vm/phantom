#!/bin/sh
# Phantom base-image provisioning — runs inside the guest as root (via the
# phantom-agent over vsock) once Setup Assistant is done and the agent is
# installed. Prepares a hands-off CI-friendly macOS: passwordless sudo, auto
# login, and no sleep / screensaver / screen lock.
#
#   phantom vm exec <vm-id> -- sh /Volumes/phantom-shared/provision.sh
#
# Assumes an admin account "admin" with password "admin".
set -e

USER_NAME=admin
USER_PASS=admin

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

echo "PROVISION_DONE"
