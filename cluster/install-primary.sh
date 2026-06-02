#!/usr/bin/env bash
# =============================================================================
# cluster/install-primary.sh
# PRIMARY node setup: MacBook Pro M2 Max 96GB or Apple Silicon 64GB+
# Installs Ollama, starts cluster discovery daemon and proxy.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"
info() { echo -e "${GREEN}[PRIMARY]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}   $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

info "=== local-ai-stack PRIMARY node setup ==="
info "Role: coordinator + large-model inference"
info "Repo root: $REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Install dependencies
# ---------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
  info "Installing Ollama..."
  brew install ollama 2>/dev/null || curl -fsSL https://ollama.com/install.sh | sh
fi
info "Ollama: $(ollama --version 2>/dev/null || echo 'installed')"

if ! command -v python3 &>/dev/null; then
  brew install python
fi
python3 -m pip install --quiet pyyaml httpx 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Configure Ollama to listen on LAN (not just localhost)
# ---------------------------------------------------------------------------
info "Configuring Ollama to bind on 0.0.0.0:11434 (LAN-visible)..."

# macOS launchd plist approach
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"
cat > "$PLIST_DIR/com.local-ai-stack.ollama.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local-ai-stack.ollama</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/ollama</string><string>serve</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>0.0.0.0:11434</string>
    <key>OLLAMA_ORIGINS</key><string>*</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/ollama.log</string>
  <key>StandardErrorPath</key><string>/tmp/ollama.err</string>
</dict>
</plist>
PLIST

# Unload existing, load new
launchctl unload "$PLIST_DIR/com.local-ai-stack.ollama.plist" 2>/dev/null || true
launchctl load -w "$PLIST_DIR/com.local-ai-stack.ollama.plist"
info "Ollama service configured and started (LAN-visible)"
sleep 2

# ---------------------------------------------------------------------------
# 3. Pull recommended models
# ---------------------------------------------------------------------------
info "Pulling recommended models for PRIMARY tier..."
DEFAULT_MODEL="${OLLAMA_MODEL:-llama3.1:70b}"

# Always pull embed model for RAG
ollama pull nomic-embed-text || warn "nomic-embed-text pull failed (non-fatal)"

# Pull main model
info "Pulling $DEFAULT_MODEL (this takes a while on first run)..."
ollama pull "$DEFAULT_MODEL" || warn "Model pull failed — check disk space"

# ---------------------------------------------------------------------------
# 4. Start discovery daemon as background process
# ---------------------------------------------------------------------------
info "Starting node discovery daemon..."
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

nohup python3 "$SCRIPT_DIR/discover.py" \
  --interval 30 \
  > "$LOG_DIR/discover.log" 2>&1 &
echo $! > "$REPO_ROOT/.discover.pid"
info "Discovery daemon PID: $(cat "$REPO_ROOT/.discover.pid")"

# ---------------------------------------------------------------------------
# 5. Start cluster proxy
# ---------------------------------------------------------------------------
info "Starting cluster proxy on port 11430..."
nohup python3 "$SCRIPT_DIR/proxy.py" \
  > "$LOG_DIR/proxy.log" 2>&1 &
echo $! > "$REPO_ROOT/.proxy.pid"
info "Cluster proxy PID: $(cat "$REPO_ROOT/.proxy.pid")"

# ---------------------------------------------------------------------------
# 6. Start Open WebUI (if Docker available)
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  info "Starting Open WebUI..."
  cd "$REPO_ROOT"
  # Point Open WebUI at the cluster proxy, not a single Ollama
  OLLAMA_BASE_URL="http://host.docker.internal:11430" docker compose up -d
  info "Open WebUI: http://localhost:3000"
else
  warn "Docker not running — skipping Open WebUI. Install Docker Desktop."
fi

info ""
info "============================================================"
info "  PRIMARY node ready!"
info ""
info "  Ollama (LAN): http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR-IP'):11434"
info "  Cluster proxy: http://localhost:11430"
info "  Open WebUI: http://localhost:3000"
info ""
info "  NEXT: Edit cluster/network-map.yaml with your node IPs"
info "  NEXT: Set pfsense DHCP reservations for each node"
info "  NEXT: Run cluster/install-qnap.sh on your QNAP"
info "  NEXT: Run cluster/install-windows-thin.ps1 on Windows PCs"
info "============================================================"
