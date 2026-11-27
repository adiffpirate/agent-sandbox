#!/usr/bin/env bash
# Probe: run --agent hermes must carry the image stamp guard, a webui env
# file, a systemd unit with a verified ExecStart, and a readiness wait.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT

sed 's/^main "\$@"$//' "$SB" > "$SCRATCH/sb"
# shellcheck disable=SC1090
source "$SCRATCH/sb" 2>/dev/null

fail() { echo "FAIL: $1"; exit 1; }

# 1. hermes env-file text: binds all interfaces + VM port, carries the secrets,
#    the agent dir and the interpreter recorded at build time.
env_text="$(hermes_webui_env_text 'test-model' '/opt/pm/venv/bin/python')"
grep -q '^HERMES_WEBUI_HOST=0.0.0.0$' <<<"$env_text" || fail "webui must bind 0.0.0.0"
grep -q "^HERMES_WEBUI_PORT=$HERMES_VM_PORT$" <<<"$env_text" || fail "webui port wrong"
grep -q '^HERMES_WEBUI_PASSWORD=' <<<"$env_text" || fail "webui password missing"
grep -q "^HERMES_WEBUI_AGENT_DIR=/home/$VM_AGENT_USER/.hermes/hermes-agent$" <<<"$env_text" || fail "agent dir missing"
grep -q '^HERMES_WEBUI_PYTHON=/opt/pm/venv/bin/python$' <<<"$env_text" || fail "agent python missing"
grep -q '^HERMES_HOME=/home/'"$VM_AGENT_USER"'/.hermes$' <<<"$env_text" || fail "HERMES_HOME missing"
grep -q '^HERMES_INFERENCE_MODEL=test-model$' <<<"$env_text" || fail "model missing"
grep -q '^OPENAI_BASE_URL=http://10.0.2.100:11434/v1$' <<<"$env_text" || fail "LLM proxy base_url missing"
grep -q '^OPENAI_API_KEY=' <<<"$env_text" || fail "api key missing"

# 2. hermes config patch: updates model routing + memory in the installer's
#    baked config.yaml without discarding its other settings. Runs for real.
patch_src="$(hermes_config_patch_text 'test-model')"
grep -q 'http://10.0.2.100:11434/v1' <<<"$patch_src" || fail "patch script missing proxy base_url"
grep -q "'provider': 'custom'\|\"provider\": \"custom\"\|provider.*custom" <<<"$patch_src" || fail "patch script missing custom provider"
printf 'model:\n  default: "anthropic/claude-opus-4.6"\n  provider: "auto"\n  base_url: "https://openrouter.ai/api/v1"\n  stream: true\nunrelated:\n  keep: 42\n' > "$SCRATCH/config.yaml"
printf '%s' "$patch_src" > "$SCRATCH/patch.py"
python3 "$SCRATCH/patch.py" "$SCRATCH/config.yaml" || fail "patch script crashed"
python3 - "$SCRATCH/config.yaml" <<'PY' || fail "patched config wrong"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
m = c["model"]
assert m["default"] == "test-model", m
assert m["provider"] == "custom", m
assert m["base_url"] == "http://10.0.2.100:11434/v1", m
assert m.get("stream") is True, "unrelated model keys must survive"
assert c["unrelated"]["keep"] == 42, "unrelated sections must survive"
assert c.get("memory", {}).get("memory_enabled") is True, "memory not enabled"
assert c.get("memory", {}).get("user_profile_enabled") is True, "user profile not enabled"
PY

# 3. unit text: runs the webui on the recorded interpreter, as the agent user.
HERMES_AGENT_PYTHON='/opt/pm/venv/bin/python'
unit="$(hermes_unit_text)"
grep -q "ExecStart=/opt/pm/venv/bin/python /opt/hermes-webui/server.py" <<<"$unit" || fail "ExecStart wrong"
grep -q 'EnvironmentFile=/etc/hermes/webui.env' <<<"$unit" || fail "env file missing in unit"
grep -q "User=$VM_AGENT_USER" <<<"$unit" || fail "unit user wrong"
grep -q 'hermes-webui' <<<"$unit" || fail "unit name/description missing"

# 4. wiring in _run: stamp guard + dispatch + mutual unit disable.
grep -q "grep -q '^hermes=' \"\$IMAGE_STAMP\"" "$SB" || fail "stamp guard for --agent hermes missing"
grep -q 'start_hermes "\$model"' "$SB" || fail "start_hermes not dispatched in _run"
grep -q 'disable_idle_agent hermes-webui' "$SB" || fail "hermes unit not disabled by the opencode path"
grep -q 'disable_idle_agent opencode' "$SB" || fail "opencode unit not disabled by the hermes path"

# 4b. the hermes stamp guard must fire BEFORE a running instance is torn down
#     (extract _run's body and check the relative order).
awk '/^_run\(\)\{/{f=1} f{print} f&&/^\}$/{exit}' "$SB" > "$SCRATCH/_run.sh"
g_pos="$(grep -n 'hermes=.*IMAGE_STAMP' "$SCRATCH/_run.sh" | head -n1 | cut -d: -f1)"
s_pos="$(grep -n 'already running' "$SCRATCH/_run.sh" | head -n1 | cut -d: -f1)"
[[ -n "$g_pos" && -n "$s_pos" && "$g_pos" -lt "$s_pos" ]] || fail "stamp guard runs after the instance teardown"
grep -q 'disable_idle_agent' "$SCRATCH/_run.sh" || fail "_run does not disable the idle agent early (boot autostart window)"

# 4c. never execute a world-writable /tmp script as root: the config patch
#     must stream straight into the interpreter.
grep -q "base64 -d | '\$agent_python' - " "$SB" || fail "config patch is not piped through stdin (root /tmp exec)"
grep -q "/tmp/hermes-config-patch.py" "$SB" && fail "root still executes a /tmp path"
# ...and it must be handed the REAL config path (agent_dir is the checkout
# inside ~/.hermes, so '$agent_dir/../.hermes/...' resolves to ~/.hermes/.hermes).
grep -Fq "base64 -d | '\$agent_python' - '/home/\$VM_AGENT_USER/.hermes/config.yaml'" "$SB" || \
  fail "config patch is not given the real config.yaml path"
true

# 4d. after the mutual disable, the starter must verify the other agent is down.
grep -c "systemctl is-active" "$SB" | grep -qE '^[2-9]' || fail "no post-disable verification of the idle agent"
grep -q 'ensure_agent_down opencode' "$SB" || fail "hermes path does not verify opencode is down"
grep -q 'ensure_agent_down hermes-webui' "$SB" || fail "opencode path does not verify hermes-webui is down"
# 'set -euo pipefail' is global: an ssh capture whose REMOTE command exits
# non-zero (is-active on a missing unit exits 4; sed on a missing file exits
# 2) kills the script mid-run. Those captures must neutralize the remote exit.
grep -q 'systemctl is-active \$unit 2>/dev/null || true' "$SB" || \
  fail "is-active capture can trip set -e (remote exit code not absorbed)"
grep -q "build-info 2>/dev/null || true" "$SB" || \
  fail "build-info capture can trip set -e (missing-file exit not absorbed)"

# 4e. _purge's stop loop must follow the recompute_instance_paths rule.
awk '/^_purge\(\)\{/{f=1} f{print} f&&/delete_sandbox_dir/{exit}' "$SB" > "$SCRATCH/purge.sh"
grep -q 'recompute_instance_paths' "$SCRATCH/purge.sh" || fail "_purge loop repoints INSTANCE_HOME without recomputing paths"
grep -q 'instance_dir%/' "$SCRATCH/purge.sh" || fail "_purge loop keeps the trailing slash on INSTANCE_HOME"

# 4f. the webui tag resolver must skip non-release tags (exp-* publishes exist).
grep -Fq '"\(v[0-9]' "$SB" || fail "webui tag resolver does not filter to vN release tags"

# 5. readiness waiter exists and targets the webui port.
declare -F wait_for_hermes >/dev/null || fail "wait_for_hermes missing"
grep -q "http://127.0.0.1:\$HERMES_WEB_PORT/health" "$SB" || fail "health probe URL wrong"

# 4g. unit files are written just before QEMU may later be SIGTERM'd: the
#     session overlay lost file DATA (0-byte file, mtime kept) twice, which
#     systemd reads as masked. Both writers must sync the write to the image.
grep -A1 'systemctl restart hermes-webui' "$SB" | grep -q '&& sync' || \
  fail "hermes unit write is not followed by sync (overlay data-loss -> masked)"
grep -A1 'systemctl restart opencode$' "$SB" | grep -q '&& sync' || \
  fail "opencode unit write is not followed by sync (overlay data-loss -> masked)"

echo "PASS"
