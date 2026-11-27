#!/usr/bin/env bash
# Probe: ONE published agent port carries whichever agent 'run --agent'
# started: a single HAProxy frontend/backend pair, a single QEMU hostfwd,
# a single guest firewall accept. There are no per-agent web/vm ports any
# more (exactly one agent runs, so they share the port).
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT

sed 's/^main "\$@"$//' "$SB" > "$SCRATCH/sb"
# shellcheck disable=SC1090
source "$SCRATCH/sb" 2>/dev/null

fail() { echo "FAIL: $1"; exit 1; }

# The shared ports must keep OpenCode's historical numbers, so existing
# bookmarks survive the merge (9090/19090 + the per-instance offset).
[[ "$AGENT_WEB_PORT" == $((9090 + INSTANCE_PORT_OFFSET)) ]] || fail "AGENT_WEB_PORT not OpenCode's old web port"
[[ "$AGENT_VM_PORT" == $((19090 + INSTANCE_PORT_OFFSET)) ]] || fail "AGENT_VM_PORT not OpenCode's old VM port"
[[ -n "${HERMES_WEB_PORT+x}" || -n "${HERMES_VM_PORT+x}" ]] && fail "per-agent Hermes web/vm vars still exist"

cfg="$(haproxy_config_text)" || fail "haproxy_config_text missing or failed"
grep -q 'frontend agent_in' <<<"$cfg" || fail "shared agent frontend missing"
grep -q "bind 0.0.0.0:$AGENT_WEB_PORT" <<<"$cfg" || fail "agent bind port wrong"
grep -q "server agent 127.0.0.1:$AGENT_VM_PORT check" <<<"$cfg" || fail "agent backend target wrong"
grep -qE 'frontend (opencode|hermes)_in' <<<"$cfg" && fail "per-agent HAProxy frontends still exist"
grep -qE 'backend (opencode|hermes)_out' <<<"$cfg" && fail "per-agent HAProxy backends still exist"
haproxy -c -f <(printf '%s\n' "$cfg") >/dev/null 2>&1 || fail "generated haproxy config does not validate"

grep -qF 'hostfwd=tcp:127.0.0.1:$AGENT_VM_PORT-:$AGENT_VM_PORT' "$SB" || fail "shared hostfwd missing"
grep -qF 'ip saddr 10.0.2.2 tcp dport $AGENT_VM_PORT accept' "$SB" || fail "guest firewall line for the shared port missing"
grep -qE '\$(OPENCODE|HERMES)_(VM|WEB)_PORT' "$SB" && fail "a per-agent port variable survives in the script"

echo "PASS"
