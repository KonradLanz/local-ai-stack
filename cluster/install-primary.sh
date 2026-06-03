#!/usr/bin/env bash
# cluster/install-primary.sh — MacBook PRIMARY node setup
# Copyright 2026 GrEEV.com KG  |  AGPL-3.0-or-later
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo ''
echo '================================================'
echo '  local-ai-stack: PRIMARY node setup'
echo '================================================'
echo ''

# --------------------------------------------------------------------------
# 0. network-map — must exist before anything else
# --------------------------------------------------------------------------
echo '[0/7] Network map...'
MAP_JSON="$REPO_ROOT/cluster/network-map.json"
MAP_YAML="$REPO_ROOT/cluster/network-map.yaml"
if [ ! -f "$MAP_JSON" ] && [ ! -f "$MAP_YAML" ]; then
  cp "$REPO_ROOT/cluster/network-map.json.example" "$MAP_JSON"
  echo '  ⚠  Created cluster/network-map.json from example'
  echo '  ⚠  Edit it with your real IPs, then re-run this script'
elif [ -f "$MAP_JSON" ]; then
  echo '  network-map.json ✓'
else
  echo '  network-map.yaml ✓'
fi

# Warn if still using example IPs
if [ -f "$MAP_JSON" ] && grep -q '192.168.1.10' "$MAP_JSON" 2>/dev/null; then
  echo ''
  echo '  ⚠⚠  network-map.json still has example IPs (192.168.1.x)'
  echo '  ⚠⚠  Edit cluster/network-map.json with your actual node IPs'
  echo '  ⚠⚠  Then run: .venv/bin/python cluster/discover.py --once'
  echo ''
fi

# --------------------------------------------------------------------------
# 1. Hardware detection
# --------------------------------------------------------------------------
echo '[1/7] Hardware detection...'
BF_LIB="$HOME/git/bootstrap-foundation/lib"
if [ ! -f "$BF_LIB/detect-hardware.sh" ]; then
  echo '  bootstrap-foundation not found — cloning...'
  mkdir -p "$HOME/git"
  git clone --depth=1 https://github.com/KonradLanz/bootstrap-foundation.git \
    "$HOME/git/bootstrap-foundation"
fi
. "$BF_LIB/detect-hardware.sh"
detect_hardware
print_hw_summary
hw_json > "$REPO_ROOT/cluster/hw-profile.json"
echo '  hw-profile.json written'
echo '  OK'

# --------------------------------------------------------------------------
# 2. Ollama
# --------------------------------------------------------------------------
echo '[2/7] Ollama...'
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.ai/install.sh | sh
fi
pgrep -x ollama &>/dev/null || (ollama serve &>/dev/null & disown; sleep 2)
echo '  OK'

# --------------------------------------------------------------------------
# 3. Python venv (isolated, only dep: pyyaml)
# --------------------------------------------------------------------------
echo '[3/7] Python venv...'
VENV="$REPO_ROOT/.venv"
[ ! -d "$VENV" ] && python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet pyyaml
echo '  .venv ready (pyyaml only)'
echo '  OK'

# --------------------------------------------------------------------------
# 4. Open WebUI
# --------------------------------------------------------------------------
echo '[4/7] Open WebUI...'
if command -v docker &>/dev/null; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'open-webui'; then
    docker compose up -d open-webui 2>/dev/null || \
      docker run -d --name open-webui \
        -p 3000:8080 \
        -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
        --restart always \
        ghcr.io/open-webui/open-webui:main
  fi
  echo '  Open WebUI: http://localhost:3000'
else
  echo '  ⚠  Docker not found — skipping Open WebUI'
fi
echo '  OK'

# --------------------------------------------------------------------------
# helper: kill stale pid file
# --------------------------------------------------------------------------
_kill_stale_pid() {
  local pid_file=$1
  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    echo "  stopping stale pid $pid..."
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pid_file"
}

# --------------------------------------------------------------------------
# 5. Mesh daemon (restart-safe)
# --------------------------------------------------------------------------
echo '[5/7] Mesh daemon...'
PID_FILE="$REPO_ROOT/.mesh-node.pid"
# Port 11430 already in use? kill whoever owns it
if lsof -ti :11430 &>/dev/null; then
  echo '  port 11430 in use — stopping old process...'
  lsof -ti :11430 | xargs kill 2>/dev/null || true
  sleep 1
fi
_kill_stale_pid "$PID_FILE"
PYTHONPATH="$REPO_ROOT" "$VENV/bin/python" -m mesh.node &
echo $! > "$PID_FILE"
echo "  started (pid $(cat "$PID_FILE"))"
echo '  OK'

# --------------------------------------------------------------------------
# 6. Discovery daemon (idempotent)
# --------------------------------------------------------------------------
echo '[6/7] Discovery daemon...'
PID_FILE2="$REPO_ROOT/.discover.pid"
if [ -f "$PID_FILE2" ] && kill -0 "$(cat "$PID_FILE2")" 2>/dev/null; then
  echo '  already running'
else
  _kill_stale_pid "$PID_FILE2"
  PYTHONPATH="$REPO_ROOT" "$VENV/bin/python" cluster/discover.py &
  echo $! > "$PID_FILE2"
  echo '  started'
fi
echo '  OK'

# --------------------------------------------------------------------------
# 7. Done
# --------------------------------------------------------------------------
echo ''
echo '================================================'
echo '  PRIMARY setup complete'
echo '================================================'
echo ''
echo "  Node profile : $HW_NODE_PROFILE"
echo "  Inference MB : $HW_INFERENCE_MB MB"
echo ''
echo '  Mesh status : http://localhost:11430/mesh/status'
echo '  Open WebUI  : http://localhost:3000'
echo ''
echo '  Health check:'
echo '    .venv/bin/python cluster/discover.py --once'
echo ''
