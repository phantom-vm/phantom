# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Documentation

- [Create a Ready-to-Use Phantom Image](docs/create-image.md) — set up a base VM with phantom-agent installed and save it as an image
- [GitLab CI Integration](docs/integration/gitlab.md) — use Phantom as a GitLab custom executor for ephemeral macOS CI jobs

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

- Prepare base macOS image
- Prepare base macOS + xcode image
- **GitLab runner: registry-backed base image** — `PHANTOM_BASE_IMAGE` currently only supports local image names. Add auto-pull from a registry reference (e.g. `registry.gitlab.com/org/macos-ci:latest`) before `vm.create`, including polling `image.status` until the pull completes.
