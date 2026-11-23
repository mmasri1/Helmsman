# Helmsman ⎈

Steering Debian toward Kubernetes. A tiny, read-only OS whose only job is to run your pods.

## Goals
- Minimal userland
- s6 instead of systemd
- containerd + kubelet, nothing more
- Read-only root

## Status
✅ Milestone 1: a minimal debootstrap (trixie) rootfs boots in QEMU.
✅ Milestone 2: systemd is gone. PID 1 is a tiny shell stage-1 that hands over to `s6-svscan`; services (serial getty, DHCP) live in `overlay/etc/s6/service`. `poweroff`/`reboot` work.
✅ Milestone 3: containerd + runc and a pinned kubelet run as s6 services, both on the cgroupfs driver (no systemd), with the kernel prerequisites checked at boot (`helmsman-kernel-check`).
✅ Milestone 4: read-only root. `/` is mounted `ro` and never remounted; all mutable state lives on a separate data partition mounted at `/var`. Next up: joining a cluster.

## Disk layout
| Partition | Label | Mounted at | Mode | Holds |
|---|---|---|---|---|
| p1 | `helmsman-root` | `/` | ro | the OS, `/etc` config (containerd, kubelet, s6 services) |
| p2 | `helmsman-data` | `/var` | rw | containerd images and snapshots, kubelet state, DHCP leases, logs |

`/run`, `/tmp` and `/dev/shm` are tmpfs. `/etc/resolv.conf` is a symlink to `/run/resolv.conf`, written by dhclient (its script follows the symlink). Init runs `fsck` on the data partition before mounting it, and shutdown unmounts it cleanly. If the data partition is missing, `/var` falls back to a tmpfs and nothing persists. Image size is set with `SIZE` (default 3G) and `ROOT_SIZE` (default 2048MiB); the data partition gets the rest.

```sh
scripts/setup-host.sh     # install tooling
scripts/build-rootfs.sh   # debootstrap minbase -> build/rootfs
scripts/make-image.sh     # BIOS/MBR raw image -> build/helmsman.img
scripts/test-boot.sh      # headless boot + reboot check (no KVM, so several minutes)
scripts/run-qemu.sh       # boot interactively on the serial console
```

## Not affiliated with Debian
Helmsman is an independent experiment built on Debian packages. It is not affiliated with or endorsed by the Debian project.

## Licenses
Helmsman's own code is MIT (see [LICENSE](LICENSE)). Packages included in images keep their own licenses.
