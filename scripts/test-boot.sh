#!/usr/bin/env bash
# Acceptance: boot headless, expect a root shell prompt on serial within TIMEOUT.
cd "$(dirname "$0")/.."
TIMEOUT=${TIMEOUT:-420}
LOG=build/boot.log
: > "$LOG"
scripts/run-qemu.sh < /dev/null > "$LOG" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT
for ((i=0; i<TIMEOUT; i+=3)); do
  if grep -q 'root@helmsman' "$LOG"; then
    echo "PASS: shell prompt after ~${i}s"; exit 0
  fi
  kill -0 $QPID 2>/dev/null || { echo "FAIL: qemu exited"; tail -20 "$LOG"; exit 1; }
  sleep 3
done
echo "FAIL: no prompt in ${TIMEOUT}s"; tail -20 "$LOG"; exit 1
