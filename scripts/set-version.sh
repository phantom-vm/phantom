#!/bin/bash
# Rewrite the version everywhere it is embedded. Called by the release
# workflow with the freshly computed version; runnable by hand too.
#
#   scripts/set-version.sh 1.2.3
#
# Touches:
#   phantom-cli/package.json          "version": "…"
#   phantom-cli/src/version.ts        VERSION constant (compiled into both CLI builds)
#   phantom-agent/Sources/Version.swift  phantomAgentVersion constant
#   phantom.xcodeproj/project.pbxproj MARKETING_VERSION (surfaces as
#                                     CFBundleShortVersionString, which
#                                     the health endpoint reports)
#
# Each rewrite is verified afterwards: a silent no-op here would release
# binaries that lie about their version.

set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <semver>  (e.g. $0 1.2.3)" >&2
    exit 1
fi

cd "$(dirname "$0")/.."

# path, sed expression, pattern that must appear afterwards
rewrite() {
    local file="$1" expr="$2" expect="$3"
    # -i.bak (suffix attached) is the one in-place form BSD and GNU sed agree
    # on — the cut job runs this on Linux, local runs are macOS.
    sed -i.bak -E "$expr" "$file"
    rm -f "$file.bak"
    if ! grep -qF "$expect" "$file"; then
        echo "error: $file does not contain '$expect' after rewrite" >&2
        exit 1
    fi
}

rewrite phantom-cli/package.json \
    's/"version": "[^"]+"/"version": "'"$VERSION"'"/' \
    "\"version\": \"$VERSION\""

rewrite phantom-cli/src/version.ts \
    's/VERSION = "[^"]+"/VERSION = "'"$VERSION"'"/' \
    "VERSION = \"$VERSION\""

rewrite phantom-agent/Sources/Version.swift \
    's/phantomAgentVersion = "[^"]+"/phantomAgentVersion = "'"$VERSION"'"/' \
    "phantomAgentVersion = \"$VERSION\""

rewrite phantom.xcodeproj/project.pbxproj \
    's/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = '"$VERSION"';/' \
    "MARKETING_VERSION = $VERSION;"

echo "version set to $VERSION"
