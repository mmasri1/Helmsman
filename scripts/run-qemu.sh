#!/usr/bin/env bash
# Boot build/helmsman.img in QEMU on the serial console (no KVM: TCG, slow).
cd "$(dirname "$0")/.."
exec qemu-system-x86_64 -machine accel=tcg -cpu max -m 1024 -smp 2 -nographic \
  -drive file=build/helmsman.img,format=raw,if=virtio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 "$@"
