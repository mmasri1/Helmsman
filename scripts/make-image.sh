#!/usr/bin/env bash
# Pack build/rootfs into a BIOS/MBR bootable raw image: build/helmsman.img
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
cd "$(dirname "$0")/.."

ROOTFS=build/rootfs
IMG=build/helmsman.img
SIZE=${SIZE:-2G}
MNT=build/mnt

[ -d "$ROOTFS" ] || { echo "run scripts/build-rootfs.sh first" >&2; exit 1; }
LOOP=
cleanup() {
  set +e
  for m in dev/pts dev proc sys; do sudo umount "$MNT/$m" 2>/dev/null; done
  sudo umount "$MNT" 2>/dev/null
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP"
}
trap cleanup EXIT

rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
sudo parted -s "$IMG" mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
LOOP=$(sudo losetup --find --show --partscan "$IMG")
sudo mkfs.ext4 -q -L helmsman-root "${LOOP}p1"
UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")

mkdir -p "$MNT"; sudo mount "${LOOP}p1" "$MNT"
sudo cp -a "$ROOTFS"/. "$MNT"/
echo "UUID=$UUID / ext4 errors=remount-ro 0 1" | sudo tee "$MNT/etc/fstab" >/dev/null

sudo mount --bind /dev "$MNT/dev"; sudo mount -t devpts devpts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"; sudo mount -t sysfs sys "$MNT/sys"
sudo mkdir -p "$MNT/etc/default/grub.d"
sudo tee "$MNT/etc/default/grub.d/helmsman.cfg" >/dev/null <<'G'
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_DISABLE_OS_PROBER=true
G
sudo chroot "$MNT" env DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends grub-pc >/dev/null' 
sudo chroot "$MNT" grub-install --target=i386-pc --modules="part_msdos ext2" "$LOOP"
sudo chroot "$MNT" update-grub
sudo chroot "$MNT" apt-get clean
sudo rm -rf "$MNT"/var/lib/apt/lists/*
echo "image ready: $IMG ($(du -h "$IMG" | cut -f1) used of $SIZE)"
