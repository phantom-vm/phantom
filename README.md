# Phantom

Run and manage macOS virtual machines on your Mac from the command line.

## Tech Stack

- Swift, SwiftUI, Virtualization.framework
- Network.framework (TCP server, zero dependencies)
- Storage: `~/Library/Application Support/phantom/`

## Roadmap

- **GitLab runner: registry-backed base image** — `PHANTOM_BASE_IMAGE` currently only supports local image names. Add auto-pull from a registry reference (e.g. `registry.gitlab.com/org/macos-ci:latest`) before `vm.create`, including polling `image.status` until the pull completes.

