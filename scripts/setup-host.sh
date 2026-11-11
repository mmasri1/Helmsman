#!/usr/bin/env bash
# Install host tools needed to build and boot a Helmsman image.
set -euo pipefail
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  debootstrap qemu-system-x86 qemu-utils parted dosfstools e2fsprogs \
  grub-pc-bin grub2-common mount util-linux
