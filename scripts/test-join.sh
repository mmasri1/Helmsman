#!/usr/bin/env bash
# Fast host-side test of overlay/usr/sbin/helmsman-join against scripts/fake-apiserver.py.
# No image or QEMU needed: state goes to a temp dir through HELMSMAN_ROOT.
# Needs curl, openssl and python3-cryptography on the host.
set -uo pipefail
cd "$(dirname "$0")/.."
JOIN=overlay/usr/sbin/helmsman-join
T=$(mktemp -d)
PORT=${PORT:-$((20000 + RANDOM % 20000))}
python3 scripts/fake-apiserver.py --dir "$T/api" --port "$PORT" --log "$T/csr.log" \
  --server-url "https://127.0.0.1:$PORT" 2>"$T/api.log" &
APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$T/api/ca-hash" ] && break; sleep 0.2; done
[ -s "$T/api/ca-hash" ] || { echo "FAIL: fake apiserver did not start"; cat "$T/api.log"; exit 1; }
HASH=$(cat "$T/api/ca-hash")
URL=https://127.0.0.1:$PORT
TOKEN=abcdef.0123456789abcdef
BAD=sha256:$(printf '0%.0s' $(seq 64))

pass=0; failed=0
ok()   { echo "ok: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; failed=$((failed+1)); }
join() { HELMSMAN_ROOT="$T/root$1" sh "$JOIN" "${@:2}" >"$T/out" 2>&1; }
expect_fail() { # label, pattern, root suffix, args...
  local label=$1 pat=$2; shift 2
  if join "$@"; then bad "$label (exit 0)"; elif grep -q -e "$pat" "$T/out"; then ok "$label"; else bad "$label: $(cat "$T/out")"; fi
}

expect_fail "rejects a plain-http server" "must be an https" 1 --server "http://127.0.0.1:$PORT" --token $TOKEN --ca-cert-hash "$HASH"
expect_fail "rejects a malformed token" "--token must look like" 1 --server "$URL" --token nope --ca-cert-hash "$HASH"
expect_fail "rejects a malformed hash" "--ca-cert-hash must be" 1 --server "$URL" --token $TOKEN --ca-cert-hash md5:abc
expect_fail "refuses a CA whose hash does not match the pin" "hash mismatch" 1 --server "$URL" --token $TOKEN --ca-cert-hash "$BAD"
[ -e "$T/root1/var/lib/kubelet/bootstrap-kubeconfig" ] && bad "wrote state after a failed join" || ok "nothing written after a failed join"
expect_fail "reports an unreachable server" "cannot fetch cluster-info" 1 --server "https://127.0.0.1:1" --token $TOKEN --ca-cert-hash "$HASH"

# A good join (upper-case hex in the pin is accepted).
UPPER=sha256:$(echo "${HASH#sha256:}" | tr a-f A-F)
if join 2 --server "$URL/" --token $TOKEN --ca-cert-hash "$UPPER" --node-name worker-1 --cluster-dns 10.32.0.10; then
  ok "join with the right pin succeeds"
else
  bad "join with the right pin: $(cat "$T/out")"
fi
R=$T/root2/var/lib
cmp -s "$R/helmsman/pki/ca.crt" "$T/api/ca.crt" && ok "cluster CA saved" || bad "cluster CA differs"
BK=$R/kubelet/bootstrap-kubeconfig
grep -q "server: $URL\$" "$BK" && grep -q "token: $TOKEN" "$BK" && grep -q "certificate-authority: $R/helmsman/pki/ca.crt" "$BK" \
  && ok "bootstrap kubeconfig has server (no trailing slash), token and CA" || bad "bootstrap kubeconfig: $(cat "$BK")"
[ "$(stat -c %a "$BK")" = 600 ] && [ "$(stat -c %a "$R/helmsman/join.env")" = 600 ] \
  && ok "token-bearing files are mode 600" || bad "modes: $(stat -c '%n %a' "$BK" "$R/helmsman/join.env")"
grep -q '^- 10.32.0.10$' "$R/helmsman/kubelet.conf.d/10-helmsman-join.conf" && grep -q '^clusterDomain: cluster.local$' "$R/helmsman/kubelet.conf.d/10-helmsman-join.conf" \
  && ok "kubelet drop-in has clusterDNS and the default clusterDomain" || bad "drop-in: $(cat "$R/helmsman/kubelet.conf.d/10-helmsman-join.conf")"
grep -qx "NODE_NAME=worker-1" "$R/helmsman/join.env" && grep -qx "CA_HASH=${HASH}" "$R/helmsman/join.env" \
  && ok "join.env records the settings (hash normalised to lower case)" || bad "join.env: $(cat "$R/helmsman/join.env")"

# Rejoin from the saved settings, after the kubelet had a (stale) kubeconfig.
echo stale > "$R/kubelet/kubeconfig"
if join 2 --from-env; then ok "--from-env rejoins from join.env"; else bad "--from-env: $(cat "$T/out")"; fi
[ ! -e "$R/kubelet/kubeconfig" ] && ok "stale kubeconfig removed so the kubelet bootstraps again" || bad "stale kubeconfig kept"
grep -qx "NODE_NAME=worker-1" "$R/helmsman/join.env" && ok "node name kept across a rejoin" || bad "node name lost"

# A seeded join.env is data, not a script.
mkdir -p "$T/root3/var/lib/helmsman"
cat > "$T/root3/var/lib/helmsman/join.env" <<EOF
# seeded
SERVER="$URL"
TOKEN=$TOKEN
CA_HASH=$HASH
NODE_NAME=\$(touch $T/pwned)x
EOF
expect_fail "join.env values are never executed" "invalid node name" 3 --from-env
[ -e "$T/pwned" ] && bad "command in join.env was executed" || ok "no command substitution from join.env"
sed -i '/^NODE_NAME/d' "$T/root3/var/lib/helmsman/join.env"
if join 3 --from-env && grep -Eq '^NODE_NAME=helmsman(-[0-9a-f]{6})?$' "$T/root3/var/lib/helmsman/join.env"; then
  ok "default node name derived from the NIC ($(grep NODE_NAME "$T/root3/var/lib/helmsman/join.env"))"
else
  bad "default node name: $(cat "$T/out")"
fi
expect_fail "--from-env without a file fails clearly" "no .*join.env" 4 --from-env

echo "$pass passed, $failed failed"
[ $failed -eq 0 ] && echo PASS
