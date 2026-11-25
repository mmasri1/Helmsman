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
✅ Milestone 4: read-only root. `/` is mounted `ro` and never remounted; all mutable state lives on a separate data partition mounted at `/var`.
✅ Milestone 5: joining a cluster. `helmsman-join` takes a kubeadm bootstrap token and CA pin, and the kubelet switches to cluster mode (TLS bootstrap, webhook authn/authz). An image can carry the join settings so every machine joins on first boot.

## Joining a cluster
On a kubeadm control plane, `kubeadm token create --print-join-command` prints a token and a CA pin. On the node:

```sh
helmsman-join --server https://10.0.0.1:6443 --token abcdef.0123456789abcdef \
              --ca-cert-hash sha256:<hex> [--node-name NAME] [--cluster-dns 10.96.0.10] [--cluster-domain cluster.local]
```

It does what `kubeadm join` does for a worker, without touching the read-only root:
1. fetches the CA from the `kube-public/cluster-info` ConfigMap,
2. refuses it unless its public-key hash matches `--ca-cert-hash`,
3. writes the CA, a bootstrap kubeconfig and a kubelet drop-in (`clusterDNS`, `clusterDomain`) under `/var`,
4. restarts the kubelet, which requests its client certificate with the token (TLS bootstrap).

The kubelet then runs `/etc/kubernetes/kubelet-cluster.yaml` instead of the standalone config. kubeadm clusters approve node CSRs from bootstrap tokens on their own; elsewhere, run `kubectl certificate approve`. The node name defaults to `helmsman-` plus the last 6 hex digits of the first NIC's MAC address, because every machine booted from one image has the same hostname.

To join without logging in, put the same settings in a `join.env` and build the image with it:

```sh
cat > join.env <<EOF
SERVER=https://10.0.0.1:6443
TOKEN=abcdef.0123456789abcdef
CA_HASH=sha256:<hex>
EOF
JOIN_ENV=join.env scripts/make-image.sh
```

The file lands on the data partition (`/var/lib/helmsman/join.env`, mode 600) and the kubelet service runs `helmsman-join --from-env` on boot until it succeeds. It is read as `KEY=VALUE` data, never executed. Bootstrap tokens expire (24h by default), so make a longer-lived one for images: `kubeadm token create --ttl 0` or a TTL of your choice.

## Disk layout
| Partition | Label | Mounted at | Mode | Holds |
|---|---|---|---|---|
| p1 | `helmsman-root` | `/` | ro | the OS, `/etc` config (containerd, kubelet, s6 services) |
| p2 | `helmsman-data` | `/var` | rw | containerd images and snapshots, kubelet state and certificates, cluster join settings, DHCP leases, logs |

`/run`, `/tmp` and `/dev/shm` are tmpfs. `/etc/resolv.conf` is a symlink to `/run/resolv.conf`, written by dhclient (its script follows the symlink). Init runs `fsck` on the data partition before mounting it, and shutdown unmounts it cleanly. If the data partition is missing, `/var` falls back to a tmpfs and nothing persists. Image size is set with `SIZE` (default 3G) and `ROOT_SIZE` (default 2048MiB); the data partition gets the rest.

```sh
scripts/setup-host.sh     # install tooling
scripts/build-rootfs.sh   # debootstrap minbase -> build/rootfs
scripts/make-image.sh     # BIOS/MBR raw image -> build/helmsman.img
scripts/test-boot.sh      # headless boot + reboot check (no KVM, so several minutes)
scripts/test-join.sh      # helmsman-join on the host against a fake API server (seconds)
scripts/test-cluster-join.sh  # boot, join the fake API server from join.env, reboot (several minutes)
scripts/run-qemu.sh       # boot interactively on the serial console
```

## Not affiliated with Debian
Helmsman is an independent experiment built on Debian packages. It is not affiliated with or endorsed by the Debian project.

## Licenses
Helmsman's own code is MIT (see [LICENSE](LICENSE)). Packages included in images keep their own licenses.
