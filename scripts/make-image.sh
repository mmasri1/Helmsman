#!/usr/bin/env bash
# Pack build/rootfs into a BIOS/MBR bootable raw image: build/helmsman.img
# Layout: p1 helmsman-root (the OS, mounted read-only), p2 helmsman-data (/var, read-write).
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
cd "$(dirname "$0")/.."

ROOTFS=build/rootfs
IMG=build/helmsman.img
SIZE=${SIZE:-3G}
ROOT_SIZE=${ROOT_SIZE:-2048MiB}   # the rest of the image goes to the data partition
MNT=build/mnt
# Optional: a join.env (SERVER, TOKEN, CA_HASH, ...; see helmsman-join) seeded onto the data
# partition, so every machine booted from this image joins the cluster on its first boot.
JOIN_ENV=${JOIN_ENV:-}

[ -d "$ROOTFS" ] || { echo "run scripts/build-rootfs.sh first" >&2; exit 1; }
if [ -n "$JOIN_ENV" ]; then
  for k in SERVER TOKEN CA_HASH; do
    grep -q "^$k=" "$JOIN_ENV" || { echo "JOIN_ENV $JOIN_ENV has no $k=" >&2; exit 1; }
  done
  grep -q '^NODE_NAME=' "$JOIN_ENV" && echo "note: NODE_NAME in $JOIN_ENV gives every machine from this image the same node name" >&2
fi
LOOP=
cleanup() {
  set +e
  for m in dev/pts dev proc sys var; do sudo umount "$MNT/$m" 2>/dev/null; done
  sudo umount "$MNT" 2>/dev/null
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP"
}
trap cleanup EXIT

rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
sudo parted -s "$IMG" mklabel msdos \
  mkpart primary ext4 1MiB "$ROOT_SIZE" set 1 boot on \
  mkpart primary ext4 "$ROOT_SIZE" 100%
LOOP=$(sudo losetup --find --show --partscan "$IMG")
sudo mkfs.ext4 -q -L helmsman-root "${LOOP}p1"
sudo mkfs.ext4 -q -L helmsman-data "${LOOP}p2"
UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")

# The image's /var is seeded onto the data partition; the root keeps an empty mount point.
mkdir -p "$MNT"; sudo mount "${LOOP}p1" "$MNT"
sudo mkdir "$MNT/var"; sudo mount "${LOOP}p2" "$MNT/var"
sudo cp -a "$ROOTFS"/. "$MNT"/
sudo tee "$MNT/etc/fstab" >/dev/null <<F
UUID=$UUID / ext4 ro,errors=remount-ro 0 1
LABEL=helmsman-data /var ext4 rw,errors=remount-ro 0 2
F
if [ -n "$JOIN_ENV" ]; then
  sudo install -d -m 0755 "$MNT/var/lib/helmsman"
  sudo install -m 0600 -o 0 -g 0 "$JOIN_ENV" "$MNT/var/lib/helmsman/join.env"
  echo "seeded join.env: the node joins $(sed -n 's/^SERVER=//p' "$JOIN_ENV") on first boot"
fi

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
# Last, now that nothing in the chroot needs DNS: resolv.conf lives in /run (dhclient-script follows the symlink).
sudo ln -sfn /run/resolv.conf "$MNT/etc/resolv.conf"
echo "image ready: $IMG ($(du -h "$IMG" | cut -f1) used of $SIZE)"
