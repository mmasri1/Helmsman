#!/usr/bin/env bash
# Build a minimal Debian (trixie) rootfs into build/rootfs with debootstrap.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
cd "$(dirname "$0")/.."

ROOTFS=build/rootfs
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
# Init is s6 (Milestone 2): no systemd-sysv; init and services come from overlay/.
INCLUDE=linux-image-cloud-amd64,s6,execline,busybox-static,isc-dhcp-client,iproute2,e2fsprogs,initramfs-tools

sudo rm -rf "$ROOTFS"
mkdir -p build
sudo debootstrap --variant=minbase --include="$INCLUDE" "$SUITE" "$ROOTFS" "$MIRROR"

# Basic config
echo helmsman | sudo tee "$ROOTFS/etc/hostname" >/dev/null
echo "127.0.0.1 localhost helmsman" | sudo tee "$ROOTFS/etc/hosts" >/dev/null
# Test-only: empty root password (serial autologin is in the s6 getty service).
sudo chroot "$ROOTFS" passwd -d root

# Make sure systemd is gone, then install the s6 init and service tree.
if sudo chroot "$ROOTFS" dpkg -s systemd >/dev/null 2>&1; then
  sudo chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get purge -y --allow-remove-essential systemd systemd-sysv
  sudo chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge
fi

# Milestone 3: container runtime (Debian's containerd + runc) and kubelet (upstream apt repo, pinned).
K8S_MINOR=${K8S_MINOR:-v1.37}
KUBELET_VERSION=${KUBELET_VERSION:-1.37.2-1.1}
sudo chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates containerd runc
sudo mkdir -p "$ROOTFS/etc/apt/keyrings"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" | sudo tee "$ROOTFS/etc/apt/keyrings/kubernetes-apt-keyring.asc" >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  | sudo tee "$ROOTFS/etc/apt/sources.list.d/kubernetes.list" >/dev/null
sudo chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive sh -c \
  "apt-get update -qq && apt-get install -y --no-install-recommends kubelet=$KUBELET_VERSION && apt-mark hold kubelet"

# systemd must not have crept back in via the new packages.
if sudo chroot "$ROOTFS" dpkg -s systemd >/dev/null 2>&1; then echo "systemd got installed" >&2; exit 1; fi
sudo cp -a overlay/. "$ROOTFS"/

# Prune
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/usr/share/doc/* "$ROOTFS"/usr/share/man/*
echo "rootfs ready: $(sudo du -sh "$ROOTFS" | cut -f1)"
