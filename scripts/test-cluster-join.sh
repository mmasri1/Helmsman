#!/usr/bin/env bash
# Acceptance for Milestone 5: boot the image against scripts/fake-apiserver.py on the
# build host (10.0.2.2 from inside QEMU) and check that
#  - helmsman-join refuses a cluster CA that does not match the pin,
#  - a join.env on the data partition makes the kubelet join on its own: it switches to
#    cluster mode and sends a node CSR (system:node:NAME, system:nodes) with the bootstrap token,
#  - after a reboot the node is still in cluster mode and bootstraps again (the fake
#    server never approves, so the kubelet keeps asking).
# TIMEOUT is per phase (seconds). Needs python3-cryptography on the host.
cd "$(dirname "$0")/.."
TIMEOUT=${TIMEOUT:-420}
PORT=${PORT:-6443}
LOG=build/join-boot.log
CSRLOG=build/join-csr.log
API=build/fake-api
FIFO=build/join-stdin.fifo
TOKEN=abcdef.0123456789abcdef
NODE=test-node-1
fail() { echo "FAIL: $1"; tail -25 "$LOG"; exit 1; }
rm -rf "$API" "$FIFO"; mkfifo "$FIFO"; : > "$LOG"; : > "$CSRLOG"

python3 scripts/fake-apiserver.py --dir "$API" --port "$PORT" --log "$CSRLOG" \
  --server-url "https://10.0.2.2:$PORT" 2> build/fake-api.log &
APID=$!
QPID=
trap 'kill $QPID $APID 2>/dev/null; rm -f "$FIFO" "$TESTIMG"' EXIT
for _ in $(seq 50); do [ -s "$API/ca-hash" ] && break; sleep 0.2; done
[ -s "$API/ca-hash" ] || { echo "FAIL: fake apiserver did not start"; cat build/fake-api.log; exit 1; }
HASH=$(cat "$API/ca-hash")
BAD=sha256:$(printf 'f%.0s' $(seq 64))
SERVER=https://10.0.2.2:$PORT

# Boot a throwaway copy: joining writes state to the data partition.
TESTIMG=build/join-test.img
cp --sparse=always build/helmsman.img "$TESTIMG" || fail "no build/helmsman.img (run scripts/make-image.sh)"
IMG=$TESTIMG scripts/run-qemu.sh < "$FIFO" > "$LOG" 2>&1 &
QPID=$!
exec 3> "$FIFO"

wait_for() { # pattern, label [, file]
  for ((i=0; i<TIMEOUT; i+=2)); do
    grep -q -e "$1" "${3:-$LOG}" && { echo "ok: $2 (~${i}s)"; return; }
    kill -0 $QPID 2>/dev/null || fail "qemu exited waiting for: $2"
    sleep 2
  done
  fail "timeout waiting for: $2"
}
wait_n() { # login-count, label: wait for a shell prompt after the Nth autologin
  for ((i=0; i<TIMEOUT; i+=2)); do
    awk -v n="$1" '/automatic login/{c++} c>=n && /root@helmsman/{f=1} END{exit !f}' "$LOG" \
      && { echo "ok: $2 (~${i}s)"; return; }
    kill -0 $QPID 2>/dev/null || fail "qemu exited waiting for: $2"
    sleep 2
  done
  fail "timeout waiting for: $2"
}
csr_count() { grep -c "cn=system:node:$NODE o=system:nodes .*token=${TOKEN%%.*}" "$CSRLOG"; }
# Which config the running kubelet was started with ([k] keeps grep from matching itself).
mode_probe() { echo "echo $1_\$(for p in /proc/[0-9]*; do tr '\\0' ' ' < \$p/cmdline 2>/dev/null; echo; done | grep -o '[k]ubelet-cluster.yaml\\|[k]ubelet.yaml' | head -1)_" >&3; }

wait_for 'root@helmsman' "shell prompt"
echo 'echo KUBELET_$(for i in $(seq 120); do busybox wget -qO- http://127.0.0.1:10248/healthz 2>/dev/null | grep -q ok && { echo healthy; exit; }; sleep 2; done)' >&3
wait_for 'KUBELET_healthy' "standalone kubelet healthy before joining"
mode_probe M0
wait_for 'M0_kubelet.yaml_' "kubelet runs the standalone config"

# A wrong pin must be refused, and leave nothing behind.
echo "helmsman-join --server $SERVER --token $TOKEN --ca-cert-hash $BAD; echo J1_\$?_\$(ls /var/lib/kubelet/bootstrap-kubeconfig 2>/dev/null | wc -l)" >&3
wait_for 'cluster CA hash mismatch' "helmsman-join refuses a CA that does not match the pin"
wait_for 'J1_1_0' "failed join exits 1 and writes no bootstrap kubeconfig"

# Seed join.env the way make-image.sh JOIN_ENV does, then let the kubelet service pick it up.
echo "mkdir -p /var/lib/helmsman; printf 'SERVER=%s\nTOKEN=%s\nCA_HASH=%s\nNODE_NAME=%s\n' $SERVER $TOKEN $HASH $NODE > /var/lib/helmsman/join.env; s6-svc -r /run/service/kubelet" >&3
# (Service output goes to /dev/console, which is tty0, so look at what the join leaves behind.)
echo 'echo JOINED_$(for i in $(seq 60); do test -s /var/lib/kubelet/bootstrap-kubeconfig && test -s /var/lib/helmsman/kubelet.conf.d/10-helmsman-join.conf && { echo yes; exit; }; sleep 2; done)' >&3
wait_for 'JOINED_yes' "kubelet service ran helmsman-join from join.env"
for ((i=0; i<TIMEOUT; i+=2)); do [ "$(csr_count)" -ge 1 ] && break; sleep 2; done
[ "$(csr_count)" -ge 1 ] || fail "no node CSR reached the API server"
echo "ok: kubelet sent a node CSR with the bootstrap token: $(grep -m1 "cn=system:node:$NODE" "$CSRLOG")"
grep -q "signer=kubernetes.io/kube-apiserver-client-kubelet" "$CSRLOG" && echo "ok: CSR asks the kubelet client signer" || fail "unexpected signer: $(cat "$CSRLOG")"
mode_probe M1
wait_for 'M1_kubelet-cluster.yaml_' "kubelet restarted in cluster mode"
echo 'echo F1_$(stat -c %a /var/lib/kubelet/bootstrap-kubeconfig /var/lib/helmsman/join.env | tr "\n" _)$(touch /etc/.probe 2>/dev/null && echo rw || echo ro)' >&3
wait_for 'F1_600_600_ro' "token files are 0600 and the root is still read-only"

# State is on /var: after a reboot the kubelet comes straight back in cluster mode.
before=$(csr_count)
echo 'sync; reboot' >&3
wait_n 2 "second boot reaches a shell prompt"
for ((i=0; i<TIMEOUT; i+=2)); do [ "$(csr_count)" -gt "$before" ] && break; sleep 2; done
[ "$(csr_count)" -gt "$before" ] || fail "no CSR after the reboot"
echo "ok: kubelet bootstraps again after the reboot ($(csr_count) CSRs in total)"
mode_probe M2
wait_for 'M2_kubelet-cluster.yaml_' "kubelet still in cluster mode after the reboot"

echo 'poweroff' >&3
for ((i=0; i<TIMEOUT; i+=2)); do
  kill -0 $QPID 2>/dev/null || { echo "ok: clean poweroff (~${i}s)"; echo PASS; exit 0; }
  sleep 2
done
fail "qemu still running after poweroff"
