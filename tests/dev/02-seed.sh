#!/usr/bin/env bash
# Probe: the generated cloud-init seed must bake in Hermes + hermes-webui
# and stay valid YAML. SB_OVERRIDE lets the probe run against an older copy.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="${SB_OVERRIDE:-$REPO/agent-sandbox}"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT

# Strip the trailing 'main "$@"' so we can source and call create_cloud_init.
sed 's/^main "\$@"$//' "$SB" > "$SCRATCH/sb"
mkdir -p "$SCRATCH/state/instances/inst-x"
# shellcheck disable=SC1090
source "$SCRATCH/sb"
SANDBOX_HOME="$SCRATCH/state"
INSTANCE_HOME="$SANDBOX_HOME/instances/inst-x"
USER_DATA="$SANDBOX_HOME/user-data"
META_DATA="$SANDBOX_HOME/meta-data"
SEED_ISO="$SANDBOX_HOME/seed.iso"
SSH_KEY="$SANDBOX_HOME/test_ed25519"; SSH_PUB="$SSH_KEY.pub"
[[ -f "$SSH_PUB" ]] || ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" >/dev/null
HERMES_WEBUI_VERSION="v0.0.0-probe" # no network in the probe

create_cloud_init "true" "0.0.0-test" "testpw"

grep -q 'agent-sandbox-install-hermes.sh' "$USER_DATA" || { echo "FAIL: installer script not invoked in runcmd"; exit 1; }
grep -q 'AS-HERMES-VERSION' "$USER_DATA" || { echo "FAIL: version console marker missing"; exit 1; }
grep -q '  - python3-venv' "$USER_DATA" || { echo "FAIL: python3-venv package missing"; exit 1; }
grep -q '  - libatomic1' "$USER_DATA" || { echo "FAIL: libatomic1 package missing"; exit 1; }
grep -q 'nesquena/hermes-webui' "$USER_DATA" || { echo "FAIL: hermes-webui clone missing"; exit 1; }
grep -q 'hermes memory status' "$USER_DATA" || { echo "FAIL: memory-backend init missing"; exit 1; }
# The agent venv must be resolved THROUGH PM (a PM-managed install has no
# in-tree venv; the generation lives under ~/.hermes/installs/*/environments/
# and facts.json records it), never by guessing in-tree .venv paths.
grep -q 'agent-sandbox-hermes-vprobe.py' "$USER_DATA" || { echo "FAIL: venv-probe helper not baked into write_files"; exit 1; }
grep -q 'committed_venv' "$USER_DATA" || { echo "FAIL: installer does not resolve the venv via pm.environments"; exit 1; }
grep -q '/etc/hermes/build-info' "$USER_DATA" || { echo "FAIL: build-info record (agent_python for run-time) missing"; exit 1; }
# runuser lines must reference $agent_home, never $HOME: the builder shell runs
# under 'set -u' with no HOME (cloud-init runcmd), and the outer shell expands
# double-quoted arguments before the guest shell ever sees them.
awk '/path: \/usr\/local\/bin\/agent-sandbox-install-hermes/{f=1;next} f&&/^chpasswd:/{exit} f' "$USER_DATA" \
  | grep -q '"\$HOME' && { echo "FAIL: installer uses \"\$HOME (expands in builder shell)"; exit 1; }
true
# The uid/gid pin entries must run BEFORE anything can leave processes owned
# by the agent user ('usermod -u' refuses a user with live processes, and the
# runcmd shell dies there under set -e, hiding the loss behind the marker gates).
awk '/^runcmd:/{f=1} f' "$USER_DATA" > "$SCRATCH/runcmd.yaml"
pin_line="$(grep -m1 -n 'usermod -u' "$SCRATCH/runcmd.yaml" | cut -d: -f1)"
hermes_line="$(grep -m1 -n '  - agent-sandbox-install-hermes.sh' "$SCRATCH/runcmd.yaml" | cut -d: -f1)"
[[ -n "$pin_line" && -n "$hermes_line" && "$pin_line" -lt "$hermes_line" ]] || \
  { echo "FAIL: uid/gid pin runs after the Hermes install (busy-user abort risk)"; exit 1; }
grep -q 'pkill -u' "$SCRATCH/runcmd.yaml" || \
  { echo "FAIL: no belt-and-braces pkill before the uid change"; exit 1; }
# final_message must not quote the sentinel: cloud-init prints it on EVERY
# boot, so a substring 'grep' for the provision marker would never fail.
awk '/^final_message:/{f=1} f' "$USER_DATA" | grep -q 'agent-sandbox-provision-ok' && \
  { echo "FAIL: final_message quotes the provision sentinel (makes the gate vacuous)"; exit 1; }
true
python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$USER_DATA" || { echo "FAIL: user-data is not valid YAML"; exit 1; }
echo "PASS"
