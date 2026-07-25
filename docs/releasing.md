# Releasing

One manual trigger cuts a whole release. In the GitHub repo: **Actions →
Release → Run workflow**, pick a bump (`patch` / `minor` / `major`).

The run has two jobs ([.github/workflows/release.yml](../.github/workflows/release.yml)):

1. **cut** — computes the next version from the latest `v*` tag, rewrites it
   everywhere via [scripts/set-version.sh](../scripts/set-version.sh), commits
   `Release vX.Y.Z` to `main`, tags it, pushes both.
2. **build** — on a macOS runner, checked out at that tag: builds the three
   binaries, checksums them, and creates the GitHub release.

They are chained with `needs:` inside one run on purpose. A tag pushed with the
workflow's own `GITHUB_TOKEN` never triggers other workflows (GitHub's
recursion guard), so a separate tag-triggered release workflow would silently
never fire.

## Assets

| Asset | What |
| --- | --- |
| `phantom` | user CLI (arm64, `bun --compile`) |
| `phantom-admin` | admin CLI — adds image authoring/publishing commands |
| `phantom-agent` | guest agent (arm64), what PHANTOM-5's bootstrap fetches |
| `phantom-app.zip` | the daemon app, ad-hoc signed |
| `SHA256SUMS.txt` | checksums of all of the above |

## Versioning

The latest `v*` tag is the source of truth; nothing in the tree needs manual
bumping. `set-version.sh` writes the version into:

- `phantom-cli/package.json` and `phantom-cli/src/version.ts` — `phantom --version`
- `phantom-agent/Sources/Version.swift` — `phantom-agent --version`
- `MARKETING_VERSION` in the Xcode project — reported by the daemon's `health`
  endpoint (a dev build built from Xcode reports whatever the tree says;
  release binaries report their tag's version)

## Downloading from a private repo

Browser asset URLs 404 without a session. Fetch via the API with a token:

```bash
# find the asset id
curl -H "Authorization: Bearer $GH_TOKEN" \
  https://api.github.com/repos/phantom-vm/phantom/releases/latest

# download (the Accept header is what turns the API URL into the binary)
curl -L -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/octet-stream" \
  https://api.github.com/repos/phantom-vm/phantom/releases/assets/<id> -o phantom
```

`gh release download` wraps the same calls.

## Caveats

- The daemon app is **ad-hoc signed**: a downloaded copy is quarantined by
  Gatekeeper (`xattr -d com.apple.quarantine` to clear). Proper Developer ID
  signing + notarization is future work.
- Everything is arm64-only, deliberately — macOS guests
  (Virtualization.framework's `VZMac*`) exist only on Apple Silicon.
