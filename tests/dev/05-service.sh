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
grep -q 'systemctl disable --now hermes-webui' "$SB" || fail "hermes unit not disabled by the opencode path"
grep -q 'systemctl disable --now opencode' "$SB" || fail "opencode unit not disabled by the hermes path"

# 5. readiness waiter exists and targets the webui port.
declare -F wait_for_hermes >/dev/null || fail "wait_for_hermes missing"
grep -q "http://127.0.0.1:\$HERMES_WEB_PORT/health" "$SB" || fail "health probe URL wrong"

echo "PASS"
