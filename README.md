# agent-sandbox

A lightweight, VM-based sandbox for running AI agents with strong isolation and air-gapped networking.

## Purpose

Running AI agents directly on your host system is crazy.
Agents can execute arbitrary shell commands, modify or delete files, behave unpredictably, and overall just do whatever they want.

> Beyond allucinations, a compromised/malicious agent can just steal your entire data over the internet,
> create backdoors on your machine, and so on...

This project provides a controlled environment to:

* Isolate agent execution inside a VM
* Share only a specific working directory
* Restrict network access to only a local LLM endpoint, everything else is denied

## Architecture

The sandbox is built using:

* QEMU/KVM for virtualization
* Alpine Linux cloud image
* Cloud-init for provisioning
* virtiofs for host directory sharing
* SSH for command execution

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

Try to run it and the script will check if something is missing ;)

## Usage

```bash
agent-sandbox help
```
