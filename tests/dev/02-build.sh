#!/usr/bin/env bash
# Probe: a completed 'agent-sandbox build' must have baked Hermes into the
# golden image: stamp lines present, real version reported on the console,
# and provisioning succeeded.
set -u
HOME_BASE="${SANDBOX_HOME_OVERRIDE:-$HOME/.local/share/agent-sandbox}"
stamp="$HOME_BASE/vm-image.stamp"
log="$HOME_BASE/build-serial.log"

[[ -f "$stamp" ]] || { echo "FAIL: no image stamp at $stamp"; exit 1; }
grep -q '^hermes=[^ ]' "$stamp" || { echo "FAIL: stamp missing hermes= line"; exit 1; }
grep -q '^hermes=unknown$' "$stamp" && { echo "FAIL: hermes version unresolved"; exit 1; }
grep -q '^hermes-webui=[^ ]' "$stamp" || { echo "FAIL: stamp missing hermes-webui= line"; exit 1; }
grep -q 'AS-HERMES-VERSION' "$log" || { echo "FAIL: no AS-HERMES-VERSION in build serial log"; exit 1; }
grep -q 'agent-sandbox-provision-ok' "$log" || { echo "FAIL: provisioning sentinel missing"; exit 1; }
echo "PASS"; sed -n 's/^/  stamp: /p' "$stamp"
