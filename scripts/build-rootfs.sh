#!/usr/bin/env bash
# Build a minimal Debian (trixie) rootfs into build/rootfs with debootstrap.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
cd "$(dirname "$0")/.."

ROOTFS=build/rootfs
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
# Milestone 1 keeps systemd; Milestone 2 swaps it for s6.
INCLUDE=linux-image-cloud-amd64,systemd-sysv,ifupdown,isc-dhcp-client,iproute2,e2fsprogs,initramfs-tools

sudo rm -rf "$ROOTFS"
mkdir -p build
sudo debootstrap --variant=minbase --include="$INCLUDE" "$SUITE" "$ROOTFS" "$MIRROR"

# Basic config
echo helmsman | sudo tee "$ROOTFS/etc/hostname" >/dev/null
echo "127.0.0.1 localhost helmsman" | sudo tee "$ROOTFS/etc/hosts" >/dev/null
sudo tee "$ROOTFS/etc/network/interfaces" >/dev/null <<'NET'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
NET
# Test-only: empty root password and autologin on the serial console.
sudo chroot "$ROOTFS" passwd -d root
sudo mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
sudo tee "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" >/dev/null <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTY

# Prune
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/usr/share/doc/* "$ROOTFS"/usr/share/man/*
echo "rootfs ready: $(sudo du -sh "$ROOTFS" | cut -f1)"
