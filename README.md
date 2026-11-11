# agent-sandbox

A lightweight, VM-based sandbox for running AI agents with strong isolation and air-gapped networking.

## Purpose

Running AI agents directly on your host system is crazy.
Agents can execute arbitrary shell commands, modify or delete files, behave unpredictably, and overall just do whatever they want.

> Beyond hallucinations, a compromised/malicious agent can just steal your entire data over the internet,
> create backdoors on your machine, and so on...

This project provides a controlled environment to:

- Isolate agent execution inside a KVM virtual machine
- Share only the current directory via virtiofs
- Restrict network access to only a local LLM endpoint (opt-out, highly recommended)
- Sync Docker images to a local registry for offline use. Docker will automatically use the registry via a [custom wrapper](https://github.com/adiffpirate/docker-wrapper-custom-registry)
- Sync files and directories from host to VM via `agent-sandbox sync file`

## Architecture

The sandbox runs a headless Ubuntu Minimal VM using QEMU/KVM with the following components:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌────────────────────────────────────────────────────┐                 │
│  │            QEMU/KVM VM (Ubuntu Minimal)            │                 │
│  │                                                    │                 │
│  │  ┌──────────────┐   ┌────────────┐   ┌──────────┐  │                 │
│  │  │  OpenCode    │   │   Docker   │   │   SSH    │  │                 │
│  │  │  (systemd)   │   │   Wrapper  │   │  :22     │  │                 │
│  │  └──────┬───────┘   └──────┬─────┘   └─────▲────┘  │                 │
│  │         │                  │               │       ├─────┐           │
│  └─────────┼──────────────────┼───────────────┼───────┘     │           │
│            │                  │               │             │           │
│  ┌─────────▼────────┐ ┌───────▼──────┐ ┌──────┴───┐ ┌───────┴────────┐  │
│  │    HAProxy       │ │  Registry    │ │   SSH    │ │  virtiofsd     │  │
│  │    :11434        │ │  :5000       │ │  :2222   │ │  (shared dir)  │  │
│  └────────┬─────────┘ └──────────────┘ └──────────┘ └────────────────┘  │
│           │                                                             │
│           │                  Host System                                │
│           │                                                             │
└───────────┼─────────────────────────────────────────────────────────────┘
            │
            │
┌───────────▼────────────────────────────┐
│  Local LLM  (e.g. Ollama / llama.cpp)  │
│  :11434                                │
└────────────────────────────────────────┘
```

### Key Design Decisions

- **Golden image system**: The VM is built once (`agent-sandbox build`) and reused across sessions. Each run creates a throwaway overlay on top of the golden image for clean state isolation.
- **Network isolation**: A HAProxy instance proxies LLM API calls from the VM to the host. An OCI registry runs locally for Docker image pulls. Network is restricted by default to only these services.
- **File sharing**: The current working directory is mounted into the VM at `/home/agent/workdir` via virtiofs. The golden image carries a `nofail` fstab entry for it, so the share is also back after a guest reboot. `--workdir-ro` is enforced twice: virtiofsd runs with `--readonly` (the enforcement point, which the guest cannot bypass) and the guest mount is remounted `ro` so the mode is visible inside the VM too.
- **Single agent**: [OpenCode V2](https://opencode.ai) is the only agent, started as a `systemd` service inside the VM and reached from the host through `opencode serve` over a password-protected HTTP endpoint.
- **Minimal base image**: Ubuntu Minimal (`ubuntu-24.04-minimal-cloudimg`), which ships cloud-init, OpenSSH, `netplan` and a virtual kernel, but no snapd, docs, editors or toolchain. The golden image adds only `git rsync nftables ripgrep vim-tiny apparmor docker.io` plus the OpenCode binary.

## Installation

### Host prerequisites

The host needs QEMU, UEFI firmware, and a way to talk to `/dev/kvm`:

```bash
# Debian / Ubuntu
sudo apt install -y curl openssh-client xorriso qemu-system-x86 qemu-utils \
                    virtiofsd uidmap ovmf moreutils haproxy socat rsync python3

# the OCI registry used for `sync docker`
curl -L https://github.com/distribution/distribution/releases/download/v3.1.0/registry_3.1.0_linux_amd64.tar.gz -o /tmp/registry.tar.gz
tar -xzf /tmp/registry.tar.gz -C "/tmp" && sudo install -m 0755 /tmp/registry /usr/local/bin/registry
# no sudo? ~/.local/bin/registry is picked up as well
```

`ensure_prereqs` prints exactly what is missing before it touches anything, and `agent-sandbox`
finds UEFI firmware (`OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd` on Debian/Ubuntu, combined
`OVMF.fd` on Alpine/openSUSE) and `virtiofsd` (`/usr/bin`, `/usr/lib/qemu`, `/usr/libexec`) itself.

KVM access:

```bash
sudo usermod -aG kvm $USER          # then start a new login session
# nested virtualisation inside a cloud VM also needs the host module option:
#   options kvm_intel nested=1   (or kvm_amd)
```

Without `/dev/kvm` access everything still works, just emulated:

```bash
SANDBOX_ACCEL=tcg agent-sandbox build
```

### Install the command

```bash
curl -L https://github.com/adiffpirate/agent-sandbox/raw/refs/heads/main/agent-sandbox -o ~/.local/bin/agent-sandbox
chmod +x ~/.local/bin/agent-sandbox
```

Verify it is on your `PATH` by running it without arguments (it prints usage and exits).

## Usage

### Build the golden image

```bash
agent-sandbox build [--vm-memory <size>] [--vm-threads <count>] [--local-llm-host <ip>] [--local-llm-port <port>]
```

Downloads the Ubuntu Minimal cloud image, then boots it once with cloud-init to install
`git rsync nftables ripgrep vim-tiny apparmor docker.io`, the OpenCode V2 binary, and the Docker
registry wrapper. Snapd and the apt caches are removed again, so the base stays small.

Pin the agent release with the environment:

```bash
OPENCODE_VERSION=2.2.7 EXTRA_PACKAGES="build-essential python3-pip" agent-sandbox build
```

The build is headless: the guest console (including all of cloud-init's output) is
written to `~/.local/share/agent-sandbox/build-serial.log`, and provisioning counts as
successful only when the guest prints the `agent-sandbox-provision-ok` marker from its
last `runcmd` step. If that marker is missing, `build` prints the tail of the console
log, throws the half-built image away and exits non-zero. Raise `BUILD_TIMEOUT`
(seconds, default 2400) on a slow machine.

### Run the agent

```bash
agent-sandbox run [--model <model>] [--context-size <size>] [--vm-memory <size>] [--vm-threads <count>] [--local-llm-host <ip>] [--local-llm-port <port>] [--restrict-network on|off] [--dns-whitelist <domains>] [--workdir-ro]
```

Starts the VM, mounts the current directory, and starts `opencode.service` in the guest.
`run` ends with the address to connect to and copy-pasteable commands; it never prints the
password, because that lives in the settings file described below.

**Note**: `agent-sandbox build` must be run before `run`.

### Settings: `.env`

The first `run` writes a `.env` file in the directory you run it from (mode `0600`) and every
later `run` reads it, so that file — not a flag — is where the two secrets live:

```bash
# API key sent to the LLM at --local-llm-host. Leave empty for an LLM that needs no key.
LLM_API_KEY=

# Password for the OpenCode UI and API (Basic auth user 'opencode').
OPENCODE_PASSWORD=<generated on the first run>
```

- **`LLM_API_KEY`** is written into the in-VM OpenCode config as
  `providers.local.settings.apiKey`, which is the key the agent sends to `--local-llm-host`.
  An empty value keeps the placeholder `local` that keyless servers use. Only
  letters, digits and `. _ : + / = -` are accepted, because the value ends up in JSON.
- **`OPENCODE_PASSWORD`** signs the browser UI, the HTTP API and the OpenCode CLI. A blank
  value means "generate a new one", never "run without a password".

**Edit the file, then rerun `agent-sandbox run`** — a rerun with a new password restarts
`opencode.service` with it, so the new password works and the old one stops working. `run`
prints `Settings: <path>` and stops if the file cannot be read or written. Two things to know:
the file sits in the shared workdir, so inside the VM it is readable as
`/home/agent/workdir/.env` (share only directories you trust), and if the workdir is a git
working tree `run` warns until `.env` is in `.gitignore`. With `--workdir-ro` the file has to
exist before the run. Older releases kept the generated password in
`~/.local/share/agent-sandbox/instances/<id>/opencode.env`; the first run moves it into `.env`
and deletes that file.

### Connect to OpenCode

HAProxy publishes the agent's port on `0.0.0.0` and OpenCode guards it with Basic auth
(username `opencode`, the password from `.env`), so all of the routes below work from the host
and from any other machine on the network. Replace `9805` with the port `run` prints.

**In a browser** — open `http://<host address>:9805`; the same address works on the host itself
and on any other machine (that is how you reach it from a laptop or a phone). The app offers a
pairing link or a password: pick **Use password**, set "Server address" to the URL you opened,
and "Password" to `OPENCODE_PASSWORD` — there is no user name in that form.

**Over the HTTP API** — OpenCode answers its usual V2 API inside the guest:

```bash
PW=$(sed -n 's/^OPENCODE_PASSWORD=//p' .env)   # the file 'run' reads
API=http://<host address>:9805                 # the address 'run' prints
AUTH="opencode:$PW"
JSON='content-type: application/json'

SESSION=$(curl -s -u "$AUTH" -H "$JSON" -X POST -d '{"title":"my-task"}' "$API/api/session" \
           | sed -n 's/.*"id":"\(ses_[^"]*\)".*/\1/p' | head -1)
curl -s -u "$AUTH" -H "$JSON" -X POST -d '{"text":"fix the build"}' \
           "$API/api/session/$SESSION/prompt" > /dev/null
curl -s -u "$AUTH" "$API/api/session/$SESSION/message"          # assistant replies
```

**With the OpenCode CLI inside the VM** (`--server` points the CLI at the running
`opencode.service` on port `19805` instead of starting its own):

```bash
agent-sandbox ssh agent \
  "cd /home/agent/workdir && OPENCODE_PASSWORD=$PW opencode --server http://10.0.2.15:19805 run 'fix the build'"
```

Inside the VM use the VM's own address (`run` prints it), because the published port is not
reachable from the guest itself. A CLI on **another** machine can call
`OPENCODE_PASSWORD=$PW opencode --server http://<host address>:9805 api <operation>`, but it
cannot open a session there: a session is bound to a directory that has to exist inside the VM,
so the browser is the remote UI.

Each session works in `/home/agent/workdir` inside the VM, which is the directory
you ran `agent-sandbox run` from: a tool call that writes a file produces that
file on the host, owned by your own uid. `GET /openapi.json` on the same port
documents the whole API.

### Sync

```bash
agent-sandbox sync docker [filter_regex]
agent-sandbox sync file <host_path>[:<vm_path>]
```

**`docker`** — Pushes local Docker images matching the filter regex to the sandbox's internal registry
so the VM can pull them without internet access. This needs a local `docker` CLI and daemon;
images that already live in the registry (`127.0.0.1:<port>/...`) are skipped. Inside the VM the
`docker` command is a wrapper that rewrites unqualified image names to `10.0.2.100:5000`, so
`docker pull alpine:3.20` resolves against the registry you just synced into.

**`file`** — Copies files or directories from the host into the VM with `rsync` (incremental).
It adds and updates files; it never deletes inside the VM (`rsync` runs without `--delete`).
If only `<host_path>` is provided, `<vm_path>` defaults to the same path
(with `/home/<user>/...` translated to `/home/agent/...`).
Paths under `/home` and `/tmp` use the `agent` user; all other paths use `root`.

### SSH into the VM

```bash
agent-sandbox ssh [agent/root] [command]
```

Opens an interactive shell or runs a command inside the VM.

### Other commands

```bash
agent-sandbox status    # Show running daemon processes
agent-sandbox stop      # Stop all daemons
agent-sandbox clean     # Stop VM and remove session overlay (keeps golden image)
agent-sandbox purge     # Delete everything including the golden image
```

### Run options

| Flag | Default | Description |
|---|---|---|
| `--model` | `code` | Model served by the local LLM endpoint |
| `--context-size` | `124000` | Context window advertised to OpenCode (output limit is half) |
| `--vm-memory` | `4G` | VM RAM (e.g. 4G, 8G) |
| `--vm-threads` | 80% of host | VM CPU threads |
| `--local-llm-host` | `192.168.0.210` | Where the host-side HAProxy forwards the VM's LLM traffic (any host on your network that speaks OpenAI-compatible HTTP; `LOCAL_LLM_HOST` overrides) |
| `--local-llm-port` | `8080` | Host port for LLM proxy |
| `--restrict-network` | `on` | Restrict VM network to only LLM and registry |
| `--dns-whitelist` | – | Comma-separated domains allowed through, e.g. `github.com,npmjs.org`. Remembered per working directory: later runs of the same directory keep it until `purge` or a new `--dns-whitelist` |
| `--workdir-ro` | `off` | Mount the shared workdir read-only |

### Build options

| Flag | Default | Description |
|---|---|---|
| `--vm-memory` | `4G` | VM RAM while cloud-init provisions the golden image |
| `--vm-threads` | 80% of host | VM CPU threads while building |
| `--local-llm-host` | `192.168.0.210` | Host IP for the LLM proxy |
| `--local-llm-port` | `8080` | Recorded as the LLM proxy port |

### Hardening

What the golden image and a running instance enforce:

- **Base image**: Ubuntu Minimal — no snapd (purged at build), no docs/man pages, no build toolchain, volatile journald capped at 64 MB. The agent account is pinned to uid 1001 / gid 1002 (`VM_AGENT_UID`/`VM_AGENT_GID`) and the build aborts if that did not happen.
- **Accounts**: a default user inherited from the base image is locked with `nologin`; SSH accepts only `agent` and `root`, publickey only, `MaxAuthTries 3`, no password/keyboard-interactive auth, no TCP forwarding or tunnels. Root has a random password that exists for the serial console only.
- **OpenCode**: runs as an unprivileged `systemd` service with `ProtectSystem=full`, `ProtectKernelTunables`, `ProtectKernelLogs`, `PrivateTmp`; inside the VM its password lives in a root-owned `0600` env file that the agent user cannot read. Free upstream models are disabled (`OPENCODE_DISABLE_FREE_MODELS=1`).
- **Secrets**: `LLM_API_KEY` and `OPENCODE_PASSWORD` live in a `0600` `.env` file in the shared workdir and are never printed by `run`. Inside the VM they are as visible as anything you share: the agent reads `/home/agent/workdir/.env`, and `LLM_API_KEY` is also written into the agent's own `opencode.json`. Share only directories you trust, and keep `.env` out of git (`run` warns if it is not ignored).
- **Outer network layer**: QEMU's user-mode NIC runs with `restrict=on`, so the guest cannot open any outbound connection that is not one of the explicit `hostfwd`/`guestfwd` channels (SSH, the OpenCode port, the LLM proxy, the registry, the whitelist proxy).
- **Guest firewall** (when `--dns-whitelist` is set): applied by `/usr/local/bin/agent-sandbox-firewall.sh apply`, which **fails closed** — if the nftables ruleset does not load, `agent-sandbox run` stops instead of starting an agent with no policy. The ruleset sets `input` policy `drop` (accepting only loopback, established flows, DHCP renewals, Docker-bridge DNS and the two host-forwarded ports) and DNATs every outbound 80/443 to the host's domain-whitelist proxy. `systemd-resolved` is masked and `/etc/resolv.conf` is made immutable so nothing can reopen DNS; AAAA queries are answered with NODATA because only IPv4 is proxied. `dns-proxy` and the ruleset are systemd units, so the policy survives a VM reboot.
- **Identity mapping**: virtiofsd maps the guest's pinned agent ids onto the host user (`--uid-map=:1001:<host uid>:1:`), which is what makes writes in `/home/agent/workdir` land on the host owned by you. If you change `VM_AGENT_UID`/`VM_AGENT_GID`, rebuild the golden image.
- **Host side**: QEMU binds the OpenCode port to `127.0.0.1` only; HAProxy is the single host listener and publishes it on `0.0.0.0`, protected by the Basic-auth password.

Notes:

- The DNAT design needs a default route in the guest; QEMU's DHCP lease supplies an address but no router, so the policy script installs `default via 10.0.2.2` itself. With `restrict=on` that route cannot reach the internet on its own.
- **DNS only works with `--dns-whitelist`**: the guest's `dns-proxy` unit forwards name queries to the host proxy, which resolves them on the host. QEMU's built-in user-mode resolver is unusable here, because it would have to reach the host's own resolver and a `systemd-resolved` stub lives on loopback. Without a whitelist the VM gets the LLM proxy, the registry and the shared workdir, and `run` says so. Removing the whitelist (`purge`, or a run without it) runs `agent-sandbox-firewall.sh remove`, which un-masks `systemd-resolved` and hands the VM a plain `/etc/resolv.conf` again.
- **Firmware**: the VM boots UEFI (OVMF). The Debian/Ubuntu split pair is attached the way EDK2 expects: the code image read-only, and a per-instance copy of `OVMF_VARS_4M.fd` as the **writable variable store**. If a host only has a single combined image, that image is attached as one writable drive instead. This matters: with no writable variable store EDK2 falls back to putting its `NvVars` file on the first filesystem the *firmware* can write to, and a VM's firmware can see the virtiofs share, so that file used to turn up inside your project directory. QEMU is also started from the sandbox state directory, so any relative-path artefact stays there. Set `OVMF_CODE_SOURCE`/`OVMF_VARS_SOURCE` to use different firmware files; the copies are re-synced from their sources whenever they no longer match.
- Add a toolchain at build time with `EXTRA_PACKAGES=...`; drop `ProtectSystem=full` in `opencode_unit_text` if a session must write outside the workdir.
