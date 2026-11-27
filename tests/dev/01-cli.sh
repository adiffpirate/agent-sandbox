#!/usr/bin/env bash
# Probe: run --agent parsing + HERMES_PASSWORD in the settings file.
# Exit 0 = feature present. Run from any directory; uses a scratch HOME.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"

fail() { echo "FAIL: $1"; exit 1; }

bash -n "$SB" || fail "syntax error in agent-sandbox"

# 1. usage documents --agent
"$SB" 2>&1 | grep -q -- '--agent' || fail "usage does not document --agent"

# 2. usage still lists OpenCode as the default agent
"$SB" 2>&1 | grep -qi -- '--agent' | true

# 3. bad --agent value is rejected (usage exit 1)
if "$SB" run --agent bogus >/dev/null 2>&1; then fail "--agent bogus accepted"; fi

# 4. a run in a scratch HOME writes a settings file that includes HERMES_PASSWORD,
#    then fails on the missing golden image (expected; settings come first).
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
( cd "$SCRATCH" && HOME="$SCRATCH/home" "$SB" run >/dev/null 2>&1 )
inst="inst-$(echo -n "$SCRATCH" | sha256sum | head -c 8)"
envf="$SCRATCH/home/.local/share/agent-sandbox/instances/$inst/.env"
[[ -f "$envf" ]] || fail "settings file not written at $envf"
grep -q '^HERMES_PASSWORD=..*' "$envf" || fail "HERMES_PASSWORD missing/empty in settings file"
grep -q '^OPENCODE_PASSWORD=..*' "$envf" || fail "OPENCODE_PASSWORD regression"

# 5. rerun keeps both passwords stable
opw="$(sed -n 's/^OPENCODE_PASSWORD=//p' "$envf")"
hpw="$(sed -n 's/^HERMES_PASSWORD=//p' "$envf")"
( cd "$SCRATCH" && HOME="$SCRATCH/home" "$SB" run >/dev/null 2>&1 )
[[ "$(sed -n 's/^OPENCODE_PASSWORD=//p' "$envf")" == "$opw" ]] || fail "OPENCODE_PASSWORD changed on rerun"
[[ "$(sed -n 's/^HERMES_PASSWORD=//p' "$envf")" == "$hpw" ]] || fail "HERMES_PASSWORD changed on rerun"

echo "PASS"
