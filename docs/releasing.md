# Releasing

One manual trigger cuts a whole release. In the GitHub repo: **Actions →
Release → Run workflow**, pick a bump (`patch` / `minor` / `major`).

**House rule: pick `minor`.** Routine releases go v1.1.0 → v1.2.0 → v1.3.0.
`patch` is reserved for shipping a fix on its own, `major` for a break in the
API or image/CLI compatibility.

The run has two jobs ([.github/workflows/release.yml](../.github/workflows/release.yml)):

1. **cut** — computes the next version from the latest `v*` tag, rewrites it
   everywhere via [scripts/set-version.sh](../scripts/set-version.sh), commits
   `Release vX.Y.Z` to `main`, tags it, pushes both.
2. **build** — on a macOS runner, checked out at that tag: builds the three
   binaries and creates the GitHub release.

They are chained with `needs:` inside one run on purpose. A tag pushed with the
workflow's own `GITHUB_TOKEN` never triggers other workflows (GitHub's
recursion guard), so a separate tag-triggered release workflow would silently
never fire.

## Assets

| Asset | What |
| --- | --- |
| `phantom-cli` | user CLI (arm64, `bun --compile`) |
| `phantom-admin-cli` | admin CLI — adds image authoring/publishing commands |
| `phantom-agent` | guest agent (arm64), what the guest bootstrap fetches |
| `phantom-daemon.zip` | the daemon app, ad-hoc signed |

Each asset's SHA-256 is computed by GitHub at upload and served as
`asset.digest`:

```bash
gh api repos/phantom-vm/phantom/releases/tags/v1.0.0 \
  -q '.assets[] | .name + "  " + .digest'
```

## Versioning

The latest `v*` tag is the source of truth; nothing in the tree needs manual
bumping. `set-version.sh` writes the version into:

- `phantom-cli/package.json` and `phantom-cli/src/version.ts` — `phantom --version`
- `phantom-agent/Sources/Version.swift` — `phantom-agent --version`
- `MARKETING_VERSION` in the Xcode project — reported by the daemon's `health`
  endpoint (a dev build built from Xcode reports whatever the tree says;
  release binaries report their tag's version)

## Downloading

Assets are plain anonymous URLs:

```bash
curl -fsSLO https://github.com/phantom-vm/phantom/releases/latest/download/phantom-cli
```

(`/latest/download/<asset>` follows the newest release; pin one with
`/download/vX.Y.Z/<asset>`. `gh release download` works too.)

## Caveats

- The daemon app is **ad-hoc signed**: a downloaded copy is quarantined by
  Gatekeeper (`xattr -d com.apple.quarantine` to clear). Proper Developer ID
  signing + notarization is future work.
- Everything is arm64-only, deliberately — macOS guests
  (Virtualization.framework's `VZMac*`) exist only on Apple Silicon.
