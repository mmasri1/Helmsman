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
# Milestone 3: kernel prerequisites, then containerd and kubelet up and answering.
# (Result markers are built with $(...) so the tty echo of the typed command can't match.)
echo helmsman-kernel-check >&3
wait_for 'KCHECK RESULT: PASS' "kernel prerequisites (overlay, br_netfilter, ip_forward, cgroup v2)"
echo 'echo CTD_$(for i in $(seq 90); do ctr version >/dev/null 2>&1 && { echo serving; exit; }; sleep 2; done)' >&3
wait_for 'CTD_serving' "containerd answers on its socket"
echo 'echo KUBELET_$(for i in $(seq 120); do busybox wget -qO- http://127.0.0.1:10248/healthz 2>/dev/null | grep -q ok && { echo healthy; exit; }; sleep 2; done)' >&3
wait_for 'KUBELET_healthy' "kubelet /healthz ok"
echo 'echo SVC_$(s6-svstat -u /run/service/containerd)_$(s6-svstat -u /run/service/kubelet)' >&3
wait_for 'SVC_true_true' "s6 reports containerd and kubelet up"
echo 'echo CG_$(grep -h cgroupDriver /var/lib/kubelet/config.yaml | tr -d " ")_$(grep -h SystemdCgroup /etc/containerd/config.toml | tr -d " ")' >&3
wait_for 'CG_cgroupDriver:cgroupfs_SystemdCgroup=false' "both configured for the cgroupfs driver"
# Runtime evidence: cgroupfs driver makes "kubepods"; the systemd driver would make kubepods.slice.
echo 'echo KP_$(test -d /sys/fs/cgroup/kubepods && ! test -e /sys/fs/cgroup/kubepods.slice && echo cgroupfs)_$(ctr plugins ls | grep -c "io.containerd.grpc.v1 *cri .* ok")' >&3
wait_for 'KP_cgroupfs_1' "kubelet really uses cgroupfs (kubepods) and containerd CRI plugin is ok"
echo poweroff >&3
for ((i=0; i<TIMEOUT; i+=2)); do
  kill -0 $QPID 2>/dev/null || { echo "ok: clean poweroff (~${i}s)"; echo PASS; exit 0; }
  sleep 2
done
fail "qemu still running after poweroff"
