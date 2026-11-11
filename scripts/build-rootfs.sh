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
sudo cp -a overlay/. "$ROOTFS"/

# Prune
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/usr/share/doc/* "$ROOTFS"/usr/share/man/*
echo "rootfs ready: $(sudo du -sh "$ROOTFS" | cut -f1)"
