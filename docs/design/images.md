# Images

Phantom supports saving VMs as OCI-compatible images that can be pushed to and pulled from any OCI registry (Docker Hub, GHCR, etc.).

## Media Types

| Content | Media Type |
|---------|-----------|
| OCI Manifest | `application/vnd.oci.image.manifest.v1+json` |
| OCI Config | `application/vnd.oci.image.config.v1+json` |
| VM Config | `application/vnd.monk-studio.phantom.config.v1` |
| NVRAM | `application/vnd.monk-studio.phantom.nvram.v1` |
| Disk Chunk (LZ4) | `application/vnd.monk-studio.phantom.disk.v1` |

## OCI Manifest Structure

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:...",
    "size": 50
  },
  "layers": [
    { "mediaType": "...phantom.config.v1", "digest": "sha256:...", "size": 456 },
    { "mediaType": "...phantom.nvram.v1", "digest": "sha256:...", "size": 789 },
    { "mediaType": "...phantom.disk.v1", "digest": "sha256:...", "size": 1024,
      "annotations": {
        "vnd.monk-studio.phantom.uncompressed-size": "536870912",
        "vnd.monk-studio.phantom.chunk-index": "0"
      }
    }
  ]
}
```

The OCI config blob is: `{"architecture":"arm64","os":"darwin"}`

## Disk Layerization

- Disk images are split into **512MB chunks**, each LZ4-compressed
- Each chunk becomes one OCI layer with `uncompressed-size` and `chunk-index` annotations
- **All-zero chunks are not stored.** A 90GB disk holding ~25GB of data has most of its slots untouched — 114 of `tahoe-base`'s 180 chunks were all-zero — and `ftruncate` alone reproduces them on restore. Dropping them costs little space (each compressed to ~3MB) but removes ~63% of the layers, and with them that share of registry objects and push/pull round trips.
- Because chunks are missing, **a layer's position no longer implies its offset**: the offset comes from `chunk-index` (or, for local chunk files, the index encoded in the `%03d.lz4` file name). Images written before this annotation existed have every chunk present, so a missing value falls back to the layer's position and they keep restoring, pushing and pulling unchanged.
- On restore: `ftruncate` creates a sparse disk, chunks are decompressed in parallel and `pwrite`-ten at their indexed offsets. Restore also skips writing any all-zero chunk it does receive (old images), keeping the file sparse. All-zero detection uses libc `memcmp` (fast even in unoptimized builds).
- Concurrency: `OCIDiskLayerizer` is `nonisolated` so compress/decompress run off the main actor; up to `min(cores, 6)` concurrent chunks (bounds peak RAM). Chunking reads each chunk with `pread` for lock-free parallel reads.

## Image Flows

**Save (VM → Local Image)**:
1. Validate VM exists and is stopped
2. Create `images/<name>/` directory
3. Base64-encode HardwareModel and MachineIdentifier into `config.json`
4. Copy AuxiliaryStorage → `nvram.bin`
5. Chunk `disk.img` → LZ4 compress → `disk/000.lz4`, `disk/002.lz4`, ... (all-zero chunks written nowhere, so the numbering has gaps)
6. Compute SHA-256 digests, write `manifest.json` with each layer's `chunk-index`

**Push (Local Image → Registry)**:
1. Read local `manifest.json`
2. For each layer: check if blob exists on registry (`HEAD`), upload if missing (`POST` + `PUT`)
3. Push manifest with tag (`PUT`)

**Pull (Registry → Local Image)**:
1. Fetch manifest from registry (`GET`), verified against the requested digest when the reference is one
2. Download all blobs (config, nvram, disk chunks) to `images/<name>/`, naming each chunk file after its layer's `chunk-index` so restore can find its offset. Disk chunks download concurrently, bounded by the same `min(cores, 6)` cap as save/restore — one connection to a registry CDN is the bottleneck, not the link: serial pulls measured ~9MB/s against ghcr where the same link pushed at ~23MB/s, and concurrency took a 58.9GB image from an estimated two hours to 41 minutes
3. Save manifest locally

**Create from Image (Local Image → VM)** — steps 2–6 run in a background task, with the VM registered in `vmInstances` up front so it is listable throughout:
1. Register in `vmInstances` as `restoring(0%)`, return the `vmId`
2. Read config JSON, decode base64 HardwareModel
3. Write HardwareModel file
4. Copy nvram.bin → AuxiliaryStorage
5. Decompress disk chunks → `pwrite` each at `chunk-index × 512MB` → `disk.img` (sparse; slots with no chunk stay holes)
6. Write the image's MachineIdentifier — **last**, because `loadExistingVMs` takes the four bundle files as proof of a usable VM, and a daemon killed mid-restore would otherwise leave a half-decompressed disk to be adopted on the next launch. An image saved before the identifier was recorded has none to restore, and falls back to a generated one
7. Boot the VM; a failure anywhere above removes the bundle and leaves the instance in `error` (which `vm.delete` clears)

## Automated Image Building (`image build`)

`phantom image build <name>` is a CLI-side orchestrator ([phantom-cli/src/commands/build.ts](../../phantom-cli/src/commands/build.ts)) that chains existing daemon endpoints into a hands-off pipeline. All the sequencing and long-polling lives in the CLI; the daemon stays a set of primitive operations.

1. **Resolve IPSW** — `ipsw.list`; use `--ipsw` or the single downloaded IPSW
2. **Install** — `vm.create` (returns `vmId` immediately), poll `vm.list` until `running`
3. **Setup Assistant** — `vm.bootScript` with `provision/setup-tahoe.txt`, poll `vm.bootScript.status` until `completed`; this also bootstraps the agent inside the guest via one VNC-typed Terminal command that fetches the published `phantom-agent-install.sh` release asset and runs it as root (the installer checks the binary against a SHA-256 pinned at release time). `--agent-url` rewrites that fetch to a dev-served installer, so agent development doesn't require cutting a release
4. **Provision** — `vm.exec` runs `provision/provision.sh` over vsock (passwordless sudo, auto-login, no sleep)
5. **Install gitlab-runner** (layered builds by default; base builds only with `--gitlab-runner`) — see below
6. **Install Xcode** (optional `--xcode <url|path>`) — see below
7. **Stop** — `vm.stop` (preceded by `sync` over vsock, since `vm.stop` is a force stop)
8. **Save** — `image.save` (`--replace` to overwrite the same name), poll `image.list` until the image appears
9. **Cleanup** — `vm.delete` the intermediate VM (unless `--keep-vm`)

**gitlab-runner** is baked into every layered image by default (base builds skip it — CI jobs run on the toolchain images layered on top, and `--gitlab-runner` forces it onto a base build), by running [provision/install-gitlab-runner.sh](../../provision/install-gitlab-runner.sh) in the guest (`RUNNER_VERSION=` prepended the same way as `XCODE_SRC=`). It curls the pinned `gitlab-runner-darwin-arm64` to `/usr/local/bin`. This is not optional cosmetics: GitLab's custom executor runs *every* stage of a job inside the job environment, so `upload_artifacts_on_success` and the cache stages shell out to `gitlab-runner artifacts-uploader` / `cache-archiver` **in the guest**. Without the binary there, those stages log `Missing gitlab-runner. Uploading artifacts is disabled.`, the job still passes, and the artifact never arrives. The step runs before Xcode so a 60MB failure surfaces in seconds rather than after a three-hour install. The guest version is pinned in the script and deliberately independent of the host runner the daemon manages — the two only need to agree on the artifact/cache protocol, not on a build.

**Layering onto an existing image** — `--image <name>` replaces steps 1–4 with a single `vm.create --fromImage` (plus the same `vm.list` poll, now watching `restoring(N%)`), since that image already has macOS installed, Setup Assistant done, the agent installed and provisioning applied. This is how toolchain images are built on top of a base: minutes of decompression instead of an hour of installing. `--image` and `--ipsw` are mutually exclusive. An image can also be layered onto *itself* (`--image <name> <name> --replace`), which is how a finished image gets a small addition — a runner bump, say — without rebuilding the toolchain.

**Xcode installation** (`--xcode <url|path>`) runs [provision/install-xcode.sh](../../provision/install-xcode.sh) inside the guest over vsock, with the source passed as an `XCODE_SRC=` line prepended to the script body (`vm.exec`'s `args` are appended to the command string, which a multi-line body cannot use). A URL is downloaded by the guest itself — no 10GB detour through the host; a local path is served to the guest over an ephemeral HTTP server bound to the host side of the vmnet NAT bridge, alive only for the duration of the install. The script expands the `.xip` (whose Apple signature `xip --expand` verifies, so it doubles as the integrity check), installs to `/Applications/Xcode.app`, then `xcode-select -s`, `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, and `DevToolsSecurity -enable` so a headless CI VM never faces an authorization prompt. Finally `xcodebuild -downloadAllPlatforms` bakes in every simulator runtime — Xcode ships with none, and paying for them once at build time beats every CI job downloading several GB before it can start.

## Image Catalog (distribution)

Users are not expected to build images. `phantom image list` shows a published catalog, and `phantom image pull <name>` fetches one by name — the same shape as `ipsw list` / `ipsw pull`.

The catalog is a one-layer OCI artifact (`vnd.monk-studio.phantom.catalog.v1+json`) living in the same registry as the images, `ghcr.io/phantom-vm/catalog:latest` by default (`PHANTOM_CATALOG` overrides it). Hosting it as an artifact keeps distribution to a single dependency, and reads are anonymous, so a fresh install can browse before it has credentials. Its entries carry a name, description, repository, sizes, and the image's **manifest digest**:

```json
{ "schemaVersion": 1,
  "images": [{ "name": "xcode-26-6", "description": "…",
               "repository": "ghcr.io/phantom-vm/xcode-26-6",
               "digest": "sha256:…", "compressedSize": 58859000000,
               "diskSize": 96636764160, "published": "2026-07-25" }] }
```

**Why the digest matters**: `image pull <name>` resolves through the catalog and pulls `repository@sha256:…`, never a tag. A digest names exact bytes, so the daemon verifies the manifest against it ([OCIRegistry.swift](../../phantom/Libs/OCI/OCIRegistry.swift)), and since every layer is already verified against its own digest, that check extends integrity to the whole image. A tag pull has nothing to compare against — hence the catalog records digests. Like the IPSW catalog, the catalog only *points*.

**Staying current**: a pull writes `pulled.json` (reference, digest, date) beside the image, because nothing else preserves the digest it came from — pushing re-encodes the manifest, so the local `manifest.json` hashes to something other than what the registry stored. `image list` compares that against the catalog and reports one of three things: current, `(update available)`, or `(Downloaded, origin unknown)` for an image built locally or pulled before this record existed. `image pull <name>` then exits early when current, replaces when the digest differs, and refuses rather than guessing when the origin is unknown (`--force` overrides). Replacement deletes the local copy before downloading — no second copy on disk, so a failed pull leaves the name empty. The catalog holds one digest per name, so there is no version history to roll back to.

**Publishing** (`phantom image publish <name>`, admin-only): push the image, read the stored manifest digest back from the registry with a `HEAD` (the daemon re-encodes the manifest when pushing, so only the registry knows the bytes it kept), then rewrite the catalog artifact with that entry. The CLI speaks OCI directly for the catalog ([phantom-cli/src/lib/oci.ts](../../phantom-cli/src/lib/oci.ts)) — it is a small JSON blob, and the daemon's client exists for multi-gigabyte layers. Credentials come from `PHANTOM_REGISTRY_USERNAME`/`PASSWORD` or `~/.docker/config.json`, the same sources the daemon uses.

## Registry Authentication

Auth follows the OCI Distribution Spec token flow:
1. First request returns 401 with `WWW-Authenticate` header
2. Parse header for Bearer realm, service, scope
3. Fetch token from auth endpoint (with Basic credentials if available)
4. Retry original request with `Authorization: Bearer <token>`

**Credential sources** (in priority order):
1. Explicit `--username`/`--password` flags
2. Environment variables: `PHANTOM_REGISTRY_USERNAME`, `PHANTOM_REGISTRY_PASSWORD`
3. `~/.docker/config.json` (auto-detected by registry hostname)
