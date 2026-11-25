#!/usr/bin/env bash
# Boot build/helmsman.img (or $IMG) in QEMU on the serial console (no KVM: TCG, slow).
cd "$(dirname "$0")/.."
IMG=${IMG:-build/helmsman.img}
exec qemu-system-x86_64 -machine accel=tcg -cpu max -m 1024 -smp 2 -nographic \
  -drive file="$IMG",format=raw,if=virtio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 "$@"
