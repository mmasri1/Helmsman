#!/usr/bin/env bash
# Acceptance: boot headless; expect a shell prompt, s6 as PID 1 (no systemd),
# and a clean poweroff that makes QEMU exit. TIMEOUT is per phase (seconds).
cd "$(dirname "$0")/.."
TIMEOUT=${TIMEOUT:-420}
LOG=build/boot.log
FIFO=build/stdin.fifo
rm -f "$FIFO"; mkfifo "$FIFO"; : > "$LOG"
scripts/run-qemu.sh < "$FIFO" > "$LOG" 2>&1 &
QPID=$!
exec 3> "$FIFO"
trap 'kill $QPID 2>/dev/null; rm -f "$FIFO"' EXIT

fail() { echo "FAIL: $1"; tail -25 "$LOG"; exit 1; }
wait_for() { # pattern, label
  for ((i=0; i<TIMEOUT; i+=2)); do
    grep -q "$1" "$LOG" && { echo "ok: $2 (~${i}s)"; return; }
    kill -0 $QPID 2>/dev/null || fail "qemu exited waiting for: $2"
    sleep 2
  done
  fail "timeout waiting for: $2"
}

wait_for 'root@helmsman' "shell prompt"
echo 'echo INIT=$(tr "\0" " " </proc/1/cmdline); echo SYSTEMD=$(test -e /run/systemd && echo yes || echo no)' >&3
wait_for 'INIT=.*s6-svscan' "PID 1 is s6-svscan"
wait_for 'SYSTEMD=no' "no systemd"
echo poweroff >&3
for ((i=0; i<TIMEOUT; i+=2)); do
  kill -0 $QPID 2>/dev/null || { echo "ok: clean poweroff (~${i}s)"; echo PASS; exit 0; }
  sleep 2
done
fail "qemu still running after poweroff"
