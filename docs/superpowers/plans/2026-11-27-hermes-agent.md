# Hermes Agent alongside OpenCode V2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake Hermes Agent + hermes-webui into the golden image next to OpenCode V2, and let `run --agent hermes|opencode` (default opencode) start the chosen agent with its web UI exposed through HAProxy.

**Architecture:** One bash script (`agent-sandbox`) drives cloud-init golden-image builds and QEMU session VMs. Hermes is installed at build time via its official source installer (pinned, self-contained toolchain under `~/.hermes`); hermes-webui is a pinned git clone with near-zero deps (pyyaml + cryptography) that runs on the agent's own venv Python. At run time only the chosen agent gets config, a systemd unit, a QEMU hostfwd, and an HAProxy frontend.

**Tech Stack:** bash, cloud-init/cloudconfig, QEMU/UEFI, systemd units written over SSH, HAProxy, hermes-agent (CalVer tags), nesquena/hermes-webui (v0.52.x tags).

**Spec:** `docs/superpowers/specs/2026-11-27-hermes-agent-design.md`

## Global Constraints

- OpenCode path must not change behavior when `--agent` is omitted; default is `opencode`.
- All Hermes/webui downloads happen at **build**; the run-time VM stays network-restricted (no new egress).
- Golden-image runcmd stays POSIX (`sh`/dash): no `set -o pipefail`, quote for `$` when embedded in the cloud-config heredoc, per existing style.
- Secrets (LLM key, passwords) never echoed: use `_ssh_quiet` for any command embedding them (existing rule).
- Version pins: `HERMES_VERSION` (git tag or branch passed to installer `--branch`; default = installer `--channel stable`), `HERMES_WEBUI_VERSION` (git tag, default = latest tag via GitHub API, same pattern as `resolve_opencode_version`).
- New ports: guest webui binds `HERMES_VM_PORT=$((19500 + INSTANCE_PORT_OFFSET))`; host HAProxy frontend `HERMES_WEB_PORT=$((9500 + INSTANCE_PORT_OFFSET))`; guest webui listens on `HERMES_VM_PORT` (mirrors OpenCode's same-port pattern).
- Settings file gains `HERMES_PASSWORD`; blank ⇒ generated, exactly like `OPENCODE_PASSWORD`.

## Review Focus

- `run` without `--agent` on an image built before this change: must fail with a clear "rebuild" message, not a broken webui (stamp has no `hermes=` line).
- `--agent hermes` with an image built before this change: same clear error.
- Restart-in-place (`run` on an active instance) switching agents: previous agent's unit must be stopped+disabled, new one enabled, ports not left bound.
- Password regeneration vs. reuse: rerun with unchanged `.env` keeps both passwords stable.
- Guest firewall (whitelist mode) must allow the webui port from `10.0.2.2` or the UI 503s through HAProxy.

---

### Task 1: CLI flag, settings file, usage text

**Files:**
- Modify: `agent-sandbox` (usage(), main() `run)` case, global vars block, `write_env_file`, `load_env_file`)

**Interfaces:**
- Produces: `CMD_AGENT` global (`opencode|hermes`), `HERMES_PASSWORD` global read/written by the settings-file helpers; consumed by Tasks 2–4.

- [ ] Step 1: In usage(): document `run --agent opencode|hermes` under Run options and the line "Runs one of two agents…"; add `HERMES_VERSION`/`HERMES_WEBUI_VERSION` under Environment overrides; replace the "The only agent this tool runs is OpenCode V2" line.
- [ ] Step 2: Globals: `CMD_AGENT="opencode"`; add `HERMES_PASSWORD=""`; add `HERMES_VERSION="${HERMES_VERSION:-}"`, `HERMES_WEBUI_VERSION="${HERMES_WEBUI_VERSION:-}"`; add `HERMES_VM_PORT`/`HERMES_WEB_PORT` per Global Constraints.
- [ ] Step 3: `main()` run-case: parse `--agent` (validate `opencode|hermes`, else `usage`), pass `"$CMD_AGENT"` into `_run` as a new last argument.
- [ ] Step 4: `write_env_file`: add `HERMES_PASSWORD` block (comment: password for the Hermes web UI). `load_env_file`: read `HERMES_PASSWORD`, generate when blank.
- [ ] Step 5: Verify: `bash -n agent-sandbox` passes; `./agent-sandbox 2>&1 | grep -c -- '--agent'` ≥ 1; in a scratch HOME run `load_env_file`-triggering path not yet (no golden image) — syntax + usage grep suffice now.
- [ ] Step 6: Commit `feat: --agent flag and HERMES_PASSWORD settings key`.

### Task 2: Golden image — install Hermes + hermes-webui at build

**Files:**
- Modify: `agent-sandbox` (`create_cloud_init`, `_build` output + stamp, packages list)

**Interfaces:**
- Consumes: `HERMES_VERSION`, `HERMES_WEBUI_VERSION` (Task 1). Produces: in-guest `~/.hermes` (agent, version recorded by `hermes --version`), `/opt/hermes-webui` with `venv` (if webui deps missing in agent venv) or agent venv reused, stamp lines `hermes=<ver>` / `hermes-webui=<ver>`.

- [ ] Step 1: `resolve_hermes_version()`: if `$HERMES_WEBUI_VERSION` set echo it; else `curl -fsSL https://api.github.com/repos/nesquena/hermes-webui/tags?per_page=1` and sed the first `"name"`. Fail like `resolve_opencode_version`.
- [ ] Step 2: packages list: add `python3-venv libatomic1` (comment why).
- [ ] Step 3: runcmd additions (as agent user via `su - $VM_AGENT_USER -c '…'`, POSIX-safe, remember `\$` escaping inside the cloud-config heredoc):
  - `git clone --depth 1 [--branch $HERMES_VERSION] https://github.com/NousResearch/hermes-agent` then `scripts/install.sh --non-interactive --skip-browser --skip-computer-use` (+ `--branch` when pinned, else `--channel stable` is the installer default).
  - `hermes --version` (fails build if launcher missing); capture to `/root/hermes-version.txt` for the stamp.
  - `git clone --depth 1 --branch $webui_version https://github.com/nesquena/hermes-webui /opt/hermes-webui`
  - Deps into the agent venv: agent python = `$HOME/.hermes/hermes-agent` launcher's python (resolve via `readlink -f $(command -v hermes)` or the wrapper's `python` line; probe at implementation). `uv pip install --python <agent-python> pyyaml cryptography` if `import yaml, cryptography` fails.
  - Memory backend init + verify: `hermes doctor` (best-effort `|| true` with output shown), `hermes memory status` (must exit 0), test -d `~/.hermes/memories`.
- [ ] Step 4: `_build`: print `Hermes : …`, add stamp lines `hermes=`/`hermes-webui=`. Hermes version in stamp: resolve latest hermes tag host-side only when pinned? No — pass empty default, let the installer choose stable; then stamp from the guest-written `/root/hermes-version.txt` (copy over SSH after build like existing flow allows; else `grep` build-serial.log). Keep it simple: after `build_golden_image`, `_ssh root cat /root/hermes-version.txt`.
- [ ] Step 5: Verify: `bash -n`; run full `agent-sandbox build` (background, expect sentinel + stamp lines; long: ~15–30 min).
- [ ] Step 6: Commit `feat: bake Hermes Agent + hermes-webui into the golden image`.

### Task 3: Run plumbing — ports, hostfwd, HAProxy, guest firewall

**Files:**
- Modify: `agent-sandbox` (`start_qemu` netdev line, `start_haproxy` config, `setup_vm_firewall` nft heredoc)

- [ ] Step 1: netdev: append `hostfwd=tcp:127.0.0.1:$HERMES_VM_PORT-:$HERMES_VM_PORT`.
- [ ] Step 2: haproxy config: add `frontend hermes_in` (`bind 0.0.0.0:$HERMES_WEB_PORT`) → `backend hermes_out` (`server hermes 127.0.0.1:$HERMES_VM_PORT check`), same timeouts as opencode frontend.
- [ ] Step 3: nft: add `ip saddr 10.0.2.2 tcp dport $HERMES_VM_PORT accept` beside the OpenCode line.
- [ ] Step 4: Verify: `bash -n`; (runtime proof comes in Task 5).
- [ ] Step 5: Commit `feat: expose the Hermes web UI through hostfwd + HAProxy`.

### Task 4: `start_hermes` service + wait + connect output

**Files:**
- Modify: `agent-sandbox` (`_run` dispatch, new `start_hermes`, `hermes_config_yaml`, `hermes_env_text`, `hermes_unit_text`, `wait_for_hermes`)

- [ ] Step 1: `_run`: if `CMD_AGENT=hermes`: first require `grep -q '^hermes=' "$IMAGE_STAMP"` — missing ⇒ ERROR "this golden image predates the Hermes agent; run 'agent-sandbox build'" and exit 1 — then `start_hermes "$model" "$context_size"`; else current `start_opencode`. In both starters: `systemctl disable --now` the *other* unit (opencode.service / hermes-webui.service) so switching agents cleanly releases ports (ignore errors).
- [ ] Step 2: config/env writers (base64 over `_ssh_quiet`, mirror opencode pattern):
  - `/home/agent/.hermes/config.yaml`: `model:` block with provider custom/openai-api + `base_url: http://10.0.2.100:11434/v1` + model name; memory block explicit (`memory_enabled: true`, `user_profile_enabled: true`). Exact keys validated in Task 5 against `hermes config get` / stub chat; fall back to env-only (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `HERMES_INFERENCE_MODEL`) if the yaml shape misbehaves.
  - `/etc/hermes/webui.env` (root, 0600): `HERMES_WEBUI_PASSWORD`, `OPENAI_API_KEY=$LLM_API_KEY` (or `local` placeholder like opencode), `HERMES_INFERENCE_MODEL=$model`, `HERMES_WEBUI_HOST=0.0.0.0`, `HERMES_WEBUI_PORT=$HERMES_VM_PORT`, `HERMES_HOME=/home/$VM_AGENT_USER/.hermes`, `HERMES_WEBUI_AGENT_DIR=/home/$VM_AGENT_USER/.hermes/hermes-agent`.
- [ ] Step 3: `hermes-webui.service` unit text mirroring `opencode_unit_text` (User/Group agent, WorkingDirectory workdir, EnvironmentFile=/etc/hermes/webui.env, `ExecStart=<agent-python> /opt/hermes-webui/server.py` — ExecStart path validated during Task 5 first boot; hardening knobs same set; `Restart=always RestartSec=2`), enable+restart.
- [ ] Step 4: `wait_for_hermes`: poll `http://127.0.0.1:$HERMES_WEB_PORT/health` (unauthenticated probe; adjust to password-authed route if /health redirects — verify Task 5); on failure dump `systemctl status hermes-webui` + webui log tail then exit 1.
- [ ] Step 5: Connect block: mirror OpenCode's output — browser URLs on `$HERMES_WEB_PORT`, `HERMES_PASSWORD` from settings file, CLI hint `agent-sandbox ssh agent 'hermes -z "…"'`, status/logs hints.
- [ ] Step 6: Verify: `bash -n`. Commit `feat: run --agent hermes brings up the Hermes web UI`.

### Task 5: E2E verification on this machine (the acceptance gate)

**Files:**
- Create: `tests/dev/stub-llm.py` (throwaway OpenAI-compatible stub: POST `/v1/chat/completions` → canned `tool_calls`-free completion echoing a magic token; stdlib http.server; also serves `/v1/models`)
- Create: `tests/dev/verify-hermes.sh` (checks below, exits non-zero on first failure)

- [ ] Step 1: Start stub LLM on host `127.0.0.1:8080` (background).
- [ ] Step 2: `./agent-sandbox run --agent hermes --local-llm-host 127.0.0.1 --vm-memory 3G` → expect `wait_for_hermes` green, connect block printed.
- [ ] Step 3: verify-hermes.sh asserts: `/health` 200; login page reachable; a chat round-trip through the webui's API reaches the stub (inspect server.py routes for the chat endpoint; if script-driving the webui API proves brittle, fall back to in-guest `hermes -z "say PONG"` one-shot round-trip + webui `/health` as the UI proof — state which was used); in-guest `hermes memory status` OK and `~/.hermes/memories/` exists; `hermes --version` matches stamp.
- [ ] Step 4: Fix whatever breaks (config keys, ExecStart, venv python path) until green; each fix gets its own commit.
- [ ] Step 5: Commit tests + fixes `test: e2e verification for the Hermes agent path`.

### Task 6: Regression — default opencode path, switching, status/stop

- [ ] Step 1: `./agent-sandbox run --local-llm-host 127.0.0.1 --vm-memory 3G` (no `--agent`) → OpenCode comes up exactly as before (`OpenCode 2.x answering on :…`).
- [ ] Step 2: `run --agent hermes …` on the *running* instance → old opencode unit disabled, hermes up; then switch back; then `stop`; `status` sane; rerun keeps both passwords stable (diff `.env`).
- [ ] Step 3: Record results in the design doc's tail ("Verification results"); fix-and-commit anything that fails.
- [ ] Step 4: Commit `docs: verification results for the Hermes branch`.

### Task 7: README

- [ ] Step 1: Update `README.md`: `run --agent`, the Hermes UI, `HERMES_PASSWORD`, build pins. Commit.
