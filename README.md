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

The sandbox runs a headless Alpine Linux VM using QEMU/KVM with the following components:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌────────────────────────────────────────────────────┐                 │
│  │             QEMU/KVM VM (Alpine Linux)             │                 │
│  │                                                    │                 │
│  │  ┌──────────────┐   ┌────────────┐   ┌──────────┐  │                 │
│  │  │    Agent     │   │   Docker   │   │   SSH    │  │                 │
│  │  │    (CLI)     │   │   Wrapper  │   │   :22    │  │                 │
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
- **File sharing**: The current working directory is mounted into the VM at `/home/agent/workdir` via virtiofs.
- **Agent support**: Supports opencode, Claude Code, and Qwen Code as agent frameworks, all configured to use the local LLM.

## Installation

Download the script and install it into your system path:

```bash
sudo curl -L \
  https://github.com/adiffpirate/agent-sandbox/raw/refs/heads/main/agent-sandbox \
  -o /usr/local/bin/agent-sandbox

sudo chmod +x /usr/local/bin/agent-sandbox
```

Verify installation:

```bash
agent-sandbox help
```

This installs `agent-sandbox` as a global command available from anywhere on your system.

## Requirements

The script will verify prerequisites automatically.

## Usage

### Build the golden image

```bash
agent-sandbox build [extra_commands]
```

Creates a golden image with all packages (bash, vim, git, curl, ripgrep, python3, npm, docker, containerd) and agent runtimes (opencode, Claude Code, Qwen Code) pre-installed.

### Run an agent

```bash
agent-sandbox run [agent] [model]
```

Starts the VM and runs the specified agent connected to your local LLM. Defaults to `opencode` with model `code`.

Supported agents:
- `opencode` — [opencode.ai](https://opencode.ai)
- `claude` — [Claude Code](https://claude.ai)
- `qwen` — [Qwen Code](https://github.com/QwenLM/qwen-code)
- `ssh` — Raw SSH session into the VM

### Sync

```bash
agent-sandbox sync docker [filter_regex]
agent-sandbox sync file <host_path>[:<vm_path>]
```

**`docker`** — Pushes local Docker images matching the filter regex to the sandbox's internal registry
so the VM can pull them without internet access.

**`file`** — Copies files or directories from the host into the VM using `scp`.
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

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `LOCAL_LLM_HOST` | `192.168.0.10` | Host where the local LLM is running |
| `LOCAL_LLM_PORT` | `11434` | Port of the local LLM |
| `VM_RESTRICT_NETWORK` | `on` | Restrict VM network to only local LLM and registry |
| `VM_MEMORY_RAM` | `2G` | VM memory allocation |
| `VM_DISK_SIZE` | `10G` | VM disk size |
