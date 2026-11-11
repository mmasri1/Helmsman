# Helmsman ⎈

Steering Debian toward Kubernetes. A tiny, read-only OS whose only job is to run your pods.

## Goals
- Minimal userland
- s6 instead of systemd
- containerd + kubelet, nothing more
- Read-only root

## Status
✅ Milestone 1: a minimal debootstrap (trixie) rootfs boots in QEMU. Still on systemd; s6 is Milestone 2.

```sh
scripts/setup-host.sh     # install tooling
scripts/build-rootfs.sh   # debootstrap minbase -> build/rootfs
scripts/make-image.sh     # BIOS/MBR raw image -> build/helmsman.img
scripts/test-boot.sh      # headless boot check (no KVM, so ~1 min)
scripts/run-qemu.sh       # boot interactively on the serial console
```

## Not affiliated with Debian
Helmsman is an independent experiment built on Debian packages. It is not affiliated with or endorsed by the Debian project.

## Licenses
Helmsman's own code is MIT (see [LICENSE](LICENSE)). Packages included in images keep their own licenses.
