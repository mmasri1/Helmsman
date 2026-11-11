# Helmsman ⎈

Steering Debian toward Kubernetes. A tiny, read-only OS whose only job is to run your pods.

## Goals
- Minimal userland
- s6 instead of systemd
- containerd + kubelet, nothing more
- Read-only root

## Status
🚧 Day zero. Nothing boots yet. Milestone 1 (a minimal debootstrap rootfs in QEMU) is next.

## Not affiliated with Debian
Helmsman is an independent experiment built on Debian packages. It is not affiliated with or endorsed by the Debian project.

## Licenses
Helmsman's own code is MIT (see [LICENSE](LICENSE)). Packages included in images keep their own licenses.
