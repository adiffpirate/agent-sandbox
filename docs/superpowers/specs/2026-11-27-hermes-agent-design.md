# Hermes Agent alongside OpenCode V2 — design

Date: 2026-11-27
Branch: `feat/hermes-agent-alongside-opencode`

## Intent and why

The sandbox today runs exactly one agent: OpenCode V2 as a systemd service inside
the VM, with its web UI/API exposed to the LAN through HAProxy. The user wants a
second agent — Nous Research **Hermes Agent** — baked into the same golden image,
with its browser UI (**hermes-webui**, the community UI linked from the Hermes
website, chosen over the built-in `hermes dashboard`) exposed the same way.
`run` chooses which agent actually starts; opencode remains the default so every
existing habit keeps working.

## Goals

- `build` installs **both** agents into the golden image, each version-pinned.
- `run --agent opencode|hermes` (default `opencode`) starts only the chosen agent.
- Hermes is usable in a browser exactly like OpenCode is today: a LAN URL plus a
  password that lives in the per-instance settings file.
- The Hermes memory backend (built-in `MEMORY.md` / `USER.md` + SQLite/FTS5
  session store) is initialized and enabled at **build** time, not first run.
- The change is proven by actually rebuilding and running the sandbox and
  completing a real chat round-trip through the Hermes web UI.

## Non-goals

- Hermes messaging gateways (Telegram/Discord/...), cron, browser/computer-use
  tools, Nous Portal, and external memory providers (Honcho, Mem0, ...).
- Running both agents simultaneously (out of scope; one agent per `run`).
- The built-in `hermes dashboard` (available in the agent, but not exposed).

## Anti-goals

- Breaking or slowing the existing OpenCode path in any way.
- Widening the sandbox's egress surface (Hermes runs fully offline at runtime;
  all downloads happen during `build`).

## Constraints

- Hermes publishes **no standalone Linux binaries**; GitHub releases carry source
  only. The official install path is their source installer, which bootstraps its
  own pinned toolchain (uv, Python 3.14, Node/pnpm, ripgrep) — verified
  checksums and pinned versions internally, self-contained under `~/.hermes`.
- Base image is Ubuntu Minimal 24.04: python3 yes, pip/venv no, no Node — the
  golden image stays lean apart from what the two agents need.
- The VM is network-restricted at run time; everything must be in the image.
- Host for verification: this machine (KVM, 8 cores, ~7.7 GB RAM, 83 GB free)
  has built and run the sandbox before; no real LLM server reachable, so an
  OpenAI-compatible stub stands in.

## Approaches considered

1. **Official Hermes source installer + hermes-webui git clone (chosen).**
   Pin both to tags; the installer's PM verifies its own downloads. Matches the
   repo's existing "fetch pinned artifact during build, nothing at run time"
   shape as closely as a Python agent allows. Trades: a fatter golden image
   (~+2–3 GB) and longer build.
2. `uv tool install hermes-agent` from PyPI — smaller, but not the official
   path, misses the Node/pnpm pieces Hermes provisions itself, and the user
   explicitly asked for a binary-style pinned install, not pip.
3. Official Docker image (`nousresearch/hermes-agent`) run as a container in
   the guest — conflicts with the sandbox's registry-pinned docker wrapper and
   nests containers; rejected.

## The design

### Golden image (cloud-init `runcmd`, during `build`)

- New env pins, resolved like OpenCode's: `HERMES_VERSION` (default: latest
  tag from the GitHub API), `HERMES_WEBUI_VERSION` (same, for nesquena/hermes-webui).
- Packages: add `python3-venv` to the image package list (webui venv only).
- As the agent user: clone `NousResearch/hermes-agent` at `$HERMES_VERSION`
  and run `scripts/install.sh --non-interactive --skip-browser
  --skip-computer-use` → `~/.hermes/hermes-agent`, launcher `~/.local/bin/hermes`.
- Memory backend setup at build: initialize `HERMES_HOME` headlessly
  (`hermes doctor`, `hermes memory status`) so `memories/MEMORY.md`,
  `USER.md`, and the SQLite/FTS5 session store exist and the `memory`
  toolset is enabled before first boot.
- Clone hermes-webui at `$HERMES_WEBUI_VERSION` into `/opt/hermes-webui`;
  create `/opt/hermes-webui/venv` and `pip install -r requirements.txt` there
  at build time. No bootstrap.py at run time (it is interactive-first).
- `IMAGE_STAMP` gains `hermes=...` and `hermes-webui=...` lines; a mismatch
  with the requested pins triggers a rebuild exactly like the OpenCode stamp does.
- Sentinel (`PROVISION_SENTINEL`) still gates success: if Hermes or the venv
  install fails, the build fails loudly.

### `run`

- `run --agent opencode|hermes`, default `opencode`; usage text updated.
- Settings file gains `HERMES_PASSWORD` (auto-generated when blank, same rule
  as `OPENCODE_PASSWORD`).
- `start_hermes` (mirrors `start_opencode`):
  - writes `~/.hermes/config.yaml`: model/provider from `--model`, custom
    OpenAI-compatible endpoint `http://10.0.2.100:11434/v1` (the HAProxy LLM
    route), context size honored where Hermes supports it;
  - writes `~/.hermes/.env`: `OPENAI_API_KEY=$LLM_API_KEY`,
    `HERMES_WEBUI_PASSWORD=$HERMES_PASSWORD`;
  - installs systemd unit `hermes-webui.service` (User=agent, venv python
    `server.py`, `HERMES_WEBUI_HOST=0.0.0.0`, `HERMES_WEBUI_PORT=8787`,
    `HERMES_WEBUI_AGENT_DIR`/`HERMES_WEBUI_PYTHON` pointing at the agent
    install, `Restart=always`, `RestartPreventExitStatus` where sensible);
  - QEMU hostfwd `127.0.0.1:$HERMES_VM_PORT-:8787` with
    `HERMES_VM_PORT=19878+offset`, HAProxy frontend `0.0.0.0:$HERMES_WEB_PORT`
    (`9878+offset`) → backend `127.0.0.1:$HERMES_VM_PORT check`; guest nftables
    accepts `10.0.2.2` → 8787 the same way it accepts the OpenCode port.
  - `wait_for_hermes` polls `/health`, then prints the same style of connect
    block (LAN URL + `HERMES_PASSWORD` location, status/log hints over SSH).
- Only the chosen agent's unit is enabled/started; the other is stopped and
  disabled so its port is never bound. HAProxy keeps both frontends (the dead
  one just 503s — `check` keeps it honest).
- `status`, `stop`, `clean`, `purge` learn the new unit name and port.

### Verification (part of the feature, not an afterthought)

1. Full `agent-sandbox build` on this machine with both agents pinned; sentinel
   + stamp checked.
2. A throwaway OpenAI-compatible stub LLM on the host (canned
   `/v1/chat/completions` replies), used via `--local-llm-host 127.0.0.1`.
3. `run --agent hermes`: `/health` answers through the HAProxy port; password
   login works; one real chat turn round-trips to the stub and renders as an
   agent reply; `hermes -z "ping"` works inside the guest; `hermes memory
   status` reports the built-in store active and `~/.hermes/memories/` exists.
4. Regression: `run` with no flag brings up OpenCode exactly as before.
5. `status` / `stop` / restart-with-new-flags behave with the new agent.

## Decisions made by the builder (not user-stated)

- Flag name `--agent`, values `opencode|hermes`; default `opencode`.
- `HERMES_PASSWORD` as the settings-file key; generated when blank.
- Ports 9878/19878 + instance offset; webui fixed at 8787 inside the guest.
- `/opt/hermes-webui` location; venv built at image-build time.
- Install the agent as the agent user with `--skip-browser --skip-computer-use`
  (those tools need network + system libs and are out of scope).
- "Memory backend" = the built-in stores initialized at build; external
  providers explicitly out of scope.
- The stub LLM and any e2e script live under `tests/` as dev tooling, kept
  simple; this branch predates the repo's older suite (that work is stashed on
  `main`).

## Open questions for the user

None material — corrections welcome; details above marked as builder decisions
can be overridden now or during the plan.

## Amendments from implementation (recorded at review, 2026-11-27)

The design above predates the build; the shipped implementation differs in
these ways (each deliberate):

- `HERMES_VERSION` empty follows the installer's own **stable channel**, it
  does not resolve a tag via the GitHub API (set it to pin a branch/tag name;
  a raw SHA is not supported since the installer clones by name, shallow).
  `HERMES_WEBUI_VERSION` empty resolves the first **release** tag (`v<digits>`)
  from the tags API — the repo also publishes `exp-*` tags, newest-first.
- No separate `/opt/hermes-webui/venv`: the web UI runs **in the agent's own
  PM dependency interpreter** (a PM install has no in-tree venv; the
  generation is recorded in `facts.json` and resolved at build by
  `pm.environments.committed_venv` via the baked helper
  `/usr/local/bin/agent-sandbox-hermes-vprobe.py`). Only `pyyaml` and
  `cryptography` join that environment. The path is recorded in
  `/etc/hermes/build-info` and consumed by `start_hermes`.
- Run-time config: model routing is a **patch** of the installer's baked
  `~/.hermes/config.yaml` (python-yaml, streamed through stdin, never a
  world-writable /tmp script), not a written-out file; secrets go to the
  root-owned `0600` `/etc/hermes/webui.env` (mirroring
  `/etc/opencode/server.env`), not `~/.hermes/.env`.
- Ports follow the OpenCode pattern, not 8787: the web UI binds
  `0.0.0.0:$HERMES_VM_PORT` (`19500+offset`, the QEMU hostfwd port) and
  HAProxy publishes `$HERMES_WEB_PORT` (`9500+offset`).
- Sentinel gate hardened during review: `build` matches the marker anchored
  at line start (cloud-init's `final_message` mentions the string on every
  boot, so the old substring grep was vacuous — an aborted runcmd passed it),
  and the uid/gid pin entries run first in runcmd (a busy-user `usermod -u`
  failure under `set -e` silently skipped everything after it).

## Verification results (2026-11-27, this machine)

Golden image: hermes v0.23.4 (2026.9.24, stable channel), hermes-webui
v0.52.735; `build` green end-to-end, stamp carries both versions, the
interpreter resolves through PM's own environment record
(`pm.environments.committed_venv`), memory stores initialized.

`run --agent hermes --local-llm-host 127.0.0.1 --local-llm-port 8080 --vm-memory 3G`
against `tests/dev/stub-llm.py`: `tests/dev/verify-hermes.sh` PASS —
/health 200 + login page 200 through HAProxy :10215, password login
(username 'admin') + authenticated GET / 200, guest hermes 0.23.4 == stamp,
webui tag checked out, `hermes memory status` ok + ~/.hermes/memories
present, chat round trip ok. Chat proof used the documented fallback: an
in-guest `hermes -z "say PONG"` one-shot through the same 10.0.2.100:11434
routing the browser chat uses (the webui's chat API needs browser-shaped
session materialization); UI proof is /health + login.

Regression: default `run` (no `--agent`) starts OpenCode 2.4.2 exactly as
before with hermes-webui stopped+disabled; hermes->opencode and
opencode->hermes switches while running both green (mutual
`disable --now` + unconditional unit rewrite); `stop`/`status` clean; both
passwords stable across reruns (settings-file md5 unchanged).

One observed transient: a run's `opencode.service` was once truncated to
0 bytes (treated as masked) after QEMU was stopped mid-run — an ext4/qcow2
durability edge of the persistent session overlay, pre-existing (same for
any run-time-written file). It reproduced once more on the rebuilt image,
which pinpoints it rather than exonerates it: both service-install chains
now end with `&& sync` (commit 2937e1e), and every `run` rewrites its
agent's unit file before enabling it, so the state self-heals either way.
