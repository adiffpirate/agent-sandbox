#!/usr/bin/env bash
# Probe: 'build' from a project directory whose instance has never existed
# must get past the firmware-copy stage (regression: the stop-all loop in
# _clean_build_artefacts used to repoint the global INSTANCE_HOME).
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$REPO/agent-sandbox"
REALH="$HOME"   # capture before the scratch HOME takes over
SCRATCH="$(mktemp -d)"
cleanup() { pkill -f "qemu-system.*$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
export HOME="$SCRATCH/home"; mkdir -p "$SCRATCH/home"
# Seed the shared state that the real machine already has (base image + keys).
mkdir -p "$SCRATCH/home/.local/share/agent-sandbox"
# An unrelated, pre-existing instance is what used to trip the stale-path bug.
mkdir -p "$SCRATCH/home/.local/share/agent-sandbox/instances/inst-fak00001"
cp -a "$REALH/.local/share/agent-sandbox/vm-base-image.qcow2" "$SCRATCH/home/.local/share/agent-sandbox/" 2>/dev/null || true
cp -a "$REALH/.local/share/agent-sandbox/agent-sandbox_ed25519"* "$SCRATCH/home/.local/share/agent-sandbox/" 2>/dev/null || true
mkdir -p "$SCRATCH/home/.local/bin"
cp -a "$REALH/.local/bin/registry" "$SCRATCH/home/.local/bin/registry" 2>/dev/null || true

out="$SCRATCH/build.out"
( cd "$REPO" && timeout 90 "$SB" build ) >"$out" 2>&1
rc=$?
if grep -q 'cannot create regular file' "$out"; then
  echo "FAIL: firmware copy hit a stale instance path"; tail -5 "$out"; exit 1
fi
if ! grep -q 'Provisioning the golden image' "$out"; then
  echo "FAIL: build never reached provisioning (rc=$rc)"; tail -15 "$out"; exit 1
fi
echo "PASS"
