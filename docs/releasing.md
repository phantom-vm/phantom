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
| `phantom-cli` | the CLI (arm64, `bun --compile`); image-authoring commands are in it, behind `PHANTOM_ADMIN_MODE` |
| `phantom-agent` | guest agent (arm64), what the guest bootstrap fetches |
| `phantom-agent-install.sh` | guest bootstrap installer — fetches `phantom-agent` from this release's versioned URL and verifies its pinned SHA-256 |
| `phantom-daemon.zip` | the daemon app, Developer ID signed and notarized |

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

## Signing

The daemon app is signed with a Developer ID Application certificate and
notarized (stapled, so Gatekeeper verifies offline). The workflow needs five
repo secrets: `MACOS_CERT_P12` (base64 .p12) + `MACOS_CERT_PASSWORD`, and
`NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` / `NOTARY_KEY_P8` (App Store Connect API
key). A release fails rather than ship if notarization is not `Accepted`.

The CLI and agent binaries are not notarized on purpose: they are fetched with
`curl`, which sets no quarantine attribute, so Gatekeeper never evaluates them.

## Caveats

- Everything is arm64-only, deliberately — macOS guests
  (Virtualization.framework's `VZMac*`) exist only on Apple Silicon.
