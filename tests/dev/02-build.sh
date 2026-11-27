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
# The stamp must hold the version line itself, not a shell-trace variant of it
# (the set -x echo line adds quotes and prefixes).
sed -n 's/^hermes=//p' "$stamp" | grep "['[:space:]]$" && { echo "FAIL: stamp hermes line has trace junk"; exit 1; }
true
grep -q '^hermes-webui=[^ ]' "$stamp" || { echo "FAIL: stamp missing hermes-webui= line"; exit 1; }
grep -q 'AS-HERMES-VERSION' "$log" || { echo "FAIL: no AS-HERMES-VERSION in build serial log"; exit 1; }
# The real marker is a raw console line; only the anchored check distinguishes
# it from incidental echoes of the same string (final_message, xtrace).
grep -qa '^agent-sandbox-provision-ok' "$log" || { echo "FAIL: provisioning sentinel missing"; exit 1; }
# And 'build' itself must anchor the same way when it gates on the marker.
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
grep -Fq 'grep -aq "^${PROVISION_SENTINEL}"' "$REPO_DIR/agent-sandbox" || \
  { echo "FAIL: build gate greps the sentinel unanchored (final_message matches vacuously)"; exit 1; }
echo "PASS"; sed -n 's/^/  stamp: /p' "$stamp"
