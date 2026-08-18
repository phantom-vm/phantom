#!/bin/sh
# Phantom image provisioning — installs the gitlab-runner binary into the guest
# as root (via the phantom-agent over vsock).
#
# GitLab's custom executor runs *every* stage of a job inside the job
# environment, not just the script: `upload_artifacts_on_success` shells out to
# `gitlab-runner artifacts-uploader`, and the cache stages to
# `cache-archiver` / `cache-extractor`. Without the binary on PATH in the guest
# those stages print "Missing gitlab-runner. Uploading artifacts is disabled."
# and are skipped — the job still passes, and the artifact never arrives. So
# every CI image needs the binary baked in; the alternative is each project
# curling 60MB in a before_script on every job.
#
#   RUNNER_VERSION=v18.11.2 sh install-gitlab-runner.sh
#
# The version is pinned here rather than derived from the host runner the daemon
# manages (GitLabRunnerManager.runnerVersion): the guest side only needs to be a
# runner recent enough to speak the same artifact/cache protocol, not the exact
# same build. Keep it roughly in step when bumping the host pin.
set -e

# Runs as admin (what a CI job is) or as root, and does the same thing either
# way. admin's sudo is passwordless, arranged by provision.sh.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

VERSION="${1:-${RUNNER_VERSION:-v18.11.2}}"
DEST=/usr/local/bin/gitlab-runner
URL="https://gitlab-runner-downloads.s3.amazonaws.com/$VERSION/binaries/gitlab-runner-darwin-arm64"

echo "Downloading gitlab-runner $VERSION..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# A guest that has only just booted may not have finished DHCP, so the first
# connect can fail outright; --retry-connrefused waits that out.
curl -fL --retry 10 --retry-delay 5 --retry-connrefused --retry-all-errors \
  --connect-timeout 10 -o "$TMP/gitlab-runner" "$URL"

# Downloaded somewhere unprivileged and installed in one step, so an interrupted
# download never leaves a half-written binary on PATH for a job to trip over.
$SUDO mkdir -p /usr/local/bin
$SUDO install -m 755 -o root -g wheel "$TMP/gitlab-runner" "$DEST"

"$DEST" --version
echo "GITLAB_RUNNER_INSTALL_DONE"
