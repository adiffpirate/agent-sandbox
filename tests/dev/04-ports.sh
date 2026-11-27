#!/usr/bin/env bash
# Probe: HAProxy config carries the Hermes frontend/backend; QEMU hostfwd and
# the guest firewall carry the Hermes VM port.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT

sed 's/^main "\$@"$//' "$SB" > "$SCRATCH/sb"
# shellcheck disable=SC1090
source "$SCRATCH/sb" 2>/dev/null

fail() { echo "FAIL: $1"; exit 1; }

cfg="$(haproxy_config_text)" || fail "haproxy_config_text missing or failed"
grep -q 'frontend opencode_in' <<<"$cfg" || fail "opencode frontend regression"
grep -q 'frontend hermes_in' <<<"$cfg" || fail "hermes frontend missing"
grep -q "bind 0.0.0.0:$HERMES_WEB_PORT" <<<"$cfg" || fail "hermes bind port wrong"
grep -q 'backend hermes_out' <<<"$cfg" || fail "hermes backend missing"
grep -q "server hermes 127.0.0.1:$HERMES_VM_PORT check" <<<"$cfg" || fail "hermes backend target wrong"
haproxy -c -f <(printf '%s\n' "$cfg") >/dev/null 2>&1 || fail "generated haproxy config does not validate"

grep -qF 'hostfwd=tcp:127.0.0.1:$HERMES_VM_PORT-:$HERMES_VM_PORT' "$SB" || fail "qemu hostfwd for hermes missing"
grep -qF 'ip saddr 10.0.2.2 tcp dport $HERMES_VM_PORT accept' "$SB" || fail "guest firewall line for hermes missing"

echo "PASS"
