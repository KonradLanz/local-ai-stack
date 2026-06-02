#!/usr/bin/env bash
# cluster/install-qnap.sh — QNAP NAS thin-worker setup
# Copyright 2026 GrEEV.com KG
# AGPL-3.0-or-later
#
# Usage (QNAP SSH):
#   PRIMARY_IP=192.168.1.10 bash <(curl -fsSL https://raw.githubusercontent.com/KonradLanz/local-ai-stack/main/cluster/install-qnap.sh)
set -euo pipefail

PRIMARY_IP="${PRIMARY_IP:-192.168.1.10}"
GITHUB_USER="${GITHUB_USER:-KonradLanz}"

# QNAP home: use /share/homes/<user>/git (writable, persistent)
QNAP_HOME="/share/homes/$(whoami)"
REPO_BASE="$QNAP_HOME/git"
REPO_DIR="$REPO_BASE/local-ai-stack"

echo ''
echo '================================================'
echo '  local-ai-stack: QNAP thin-worker setup'
echo '================================================'
echo ''

# --------------------------------------------------------------------------
# 1. Writable home
# --------------------------------------------------------------------------
echo '[1/5] Writable base dir...'
mkdir -p "$REPO_BASE"
echo "  $REPO_BASE  OK"

# --------------------------------------------------------------------------
# 2. Clone / update repo
# --------------------------------------------------------------------------
echo '[2/5] Repo...'
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone --depth=1 \
    "https://github.com/$GITHUB_USER/local-ai-stack.git" \
    "$REPO_DIR"
else
  git -C "$REPO_DIR" pull --ff-only
fi
echo "  $REPO_DIR  OK"

# --------------------------------------------------------------------------
# 3. bootstrap-foundation (hardware detection)
# --------------------------------------------------------------------------
echo '[3/5] bootstrap-foundation...'
BF_DIR="$REPO_BASE/bootstrap-foundation"
if [ ! -d "$BF_DIR/.git" ]; then
  git clone --depth=1 \
    "https://github.com/$GITHUB_USER/bootstrap-foundation.git" \
    "$BF_DIR"
else
  git -C "$BF_DIR" pull --ff-only
fi
. "$BF_DIR/lib/detect-hardware.sh" || true
export_hw_profile 2>/dev/null && echo '  hw-profile.json written' || echo '  hw detection skipped'

# --------------------------------------------------------------------------
# 4. Ollama (Container Station / Docker)
# --------------------------------------------------------------------------
echo '[4/5] Ollama...'
if command -v docker &>/dev/null; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'ollama'; then
    docker run -d --name ollama \
      -p 11434:11434 \
      -v ollama:/root/.ollama \
      --restart always \
      ollama/ollama:latest
    sleep 3
    echo '  Ollama container started'
  else
    echo '  Ollama already running'
  fi
elif command -v ollama &>/dev/null; then
  echo '  Ollama binary found'
else
  echo '  ⚠  No Docker and no ollama binary — install Ollama via Container Station'
fi

# --------------------------------------------------------------------------
# 5. Mesh node daemon (Python stdlib only — no pip needed)
# --------------------------------------------------------------------------
echo '[5/5] Mesh daemon...'
cd "$REPO_DIR"
PYTHON=$(command -v python3 || command -v python || echo '')
if [ -z "$PYTHON" ]; then
  echo '  ⚠  No Python found — mesh daemon skipped'
else
  PID_FILE="$REPO_DIR/.mesh-node.pid"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo '  already running'
  else
    MESH_PORT=11430 "$PYTHON" -m mesh.node &
    echo $! > "$PID_FILE"
    echo "  started (pid $(cat "$PID_FILE"))"
  fi
fi

echo ''
echo '================================================'
echo "  QNAP setup complete — reporting to $PRIMARY_IP"
echo '================================================'
echo ''
echo "  Mesh node:  http://$(hostname -I | awk '{print $1}'):11430/mesh/status"
echo ''
