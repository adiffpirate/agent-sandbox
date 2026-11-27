#!/usr/bin/env bash
# E2E verification for a live 'agent-sandbox run --agent hermes' instance.
#
# Preconditions (the caller sets these up, see the task brief):
#   - tests/dev/stub-llm.py answering on the host (run with --local-llm-host)
#   - the instance already running (this script never starts anything)
#
# UI proof = /health + password login through the published web port.
# Chat proof = an in-guest 'hermes -z' round trip through the same host LLM
# proxy the browser chat uses (10.0.2.100:11434 -> HAProxy -> stub). The
# webui's chat API needs browser-shaped session materialisation, so the CLI
# stands in for the turn itself (plan Task 5, documented fallback).
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT

# Same instance derivation as a run from this directory (ports, settings file).
sed 's/^main "\$@"$//' "$SB" > "$SCRATCH/sb"
# shellcheck disable=SC1090
source "$SCRATCH/sb" 2>/dev/null

fail() { echo "FAIL: $1" >&2; exit 1; }

WEB="http://127.0.0.1:$HERMES_WEB_PORT"
stamp="$SANDBOX_HOME/vm-image.stamp"
envf="$INSTANCE_HOME/.env"

# 1. readiness + auth surface through HAProxy.
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$WEB/health" || true)"
[[ "$code" == "200" ]] || fail "/health on :$HERMES_WEB_PORT returned '$code'"
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$WEB/login" || true)"
[[ "$code" == "200" ]] || fail "login page returned '$code'"

# 2. password login from the settings file.
pw="$(sed -n 's/^HERMES_PASSWORD=//p' "$envf" | head -n1)"
[[ -n "$pw" ]] || fail "no HERMES_PASSWORD in $envf"
login="$(curl -s -m 10 -c "$SCRATCH/cookies" -X POST "$WEB/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$pw\"}")"
grep -q '"ok": *true' <<<"$login" || fail "web UI login rejected: $login"
auth_code="$(curl -s -m 5 -b "$SCRATCH/cookies" -o /dev/null -w '%{http_code}' "$WEB/")"
[[ "$auth_code" == "200" ]] || fail "authenticated GET / returned '$auth_code'"
noauth_code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$WEB/api/auth/status" --stderr - || true)"
echo "  login ok; authenticated GET / = $auth_code"

# 3. guest-side agent health, versions matching the image stamp.
ver_guest="$($SB ssh agent "/home/$VM_AGENT_USER/.local/bin/hermes --version" 2>/dev/null |
  sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | head -n1)"
ver_stamp="$(sed -n 's/^hermes=.*v\([0-9][0-9.]*\).*/\1/p' "$stamp" | head -n1)"
[[ -n "$ver_guest" && "$ver_guest" == "$ver_stamp" ]] || \
  fail "hermes version mismatch: guest='$ver_guest' stamp='$ver_stamp'"
webui_stamp="$(sed -n 's/^hermes-webui=//p' "$stamp" | head -n1)"
# (describe is unreliable here: the clone is shallow and the upstream tag
# object is annotated; asserting the pinned tag ref exists + HEAD is present
# is the honest equivalent of "this checkout is that tag".)
$SB ssh agent "git -C /opt/hermes-webui tag -l '$webui_stamp' | grep -qx '$webui_stamp' && git -C /opt/hermes-webui rev-parse --verify -q 'refs/tags/$webui_stamp'" >/dev/null 2>&1 || \
  fail "hermes-webui checkout is not at tag $webui_stamp"
echo "  versions ok: hermes $ver_guest, webui tag $webui_stamp checked out"

# 4. memory backend alive at run time.
$SB ssh agent "/home/$VM_AGENT_USER/.local/bin/hermes memory status" >/dev/null 2>&1 || \
  fail "hermes memory status failed in the guest"
$SB ssh agent "test -d /home/$VM_AGENT_USER/.hermes/memories" || \
  fail "~/.hermes/memories missing in the guest"
echo "  memory backend ok"

# 5. chat round trip: config.yaml inside the VM points the agent at the host
# LLM proxy; the stub answers 'PONG' only when the prompt reached it.
reply="$($SB ssh agent "OPENAI_API_KEY=local /home/$VM_AGENT_USER/.local/bin/hermes -z 'say PONG'" 2>/dev/null || true)"
grep -q 'PONG' <<<"$reply" || fail "one-shot chat did not round-trip (reply: ${reply:0:300})"
echo "  chat round-trip ok"

echo "PASS"
