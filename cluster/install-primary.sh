#!/usr/bin/env bash
# =============================================================================
# cluster/install-primary.sh
# PRIMARY coordinator setup (MacBook Pro / Apple Silicon 32GB+)
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[PRIMARY]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()  { echo -e "${CYAN}[STEP]${RESET}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Load shared detection from bootstrap-foundation
# ---------------------------------------------------------------------------
step "Loading OS + hardware detection from bootstrap-foundation..."

# Locate bootstrap-foundation: sibling directory or $BOOTSTRAP_FOUNDATION env
BF_LIB="${BOOTSTRAP_FOUNDATION:-$(cd "$REPO_ROOT/../bootstrap-foundation" 2>/dev/null && pwd)}/lib"

if [ ! -d "$BF_LIB" ]; then
  warn "bootstrap-foundation/lib not found at $BF_LIB"
  warn "Cloning bootstrap-foundation next to this repo..."
  git clone https://github.com/KonradLanz/bootstrap-foundation.git \
    "$(dirname "$REPO_ROOT")/bootstrap-foundation"
  BF_LIB="$(dirname "$REPO_ROOT")/bootstrap-foundation/lib"
fi

# shellcheck source=../../bootstrap-foundation/lib/detect-os.sh
. "$BF_LIB/detect-os.sh"
detect_os

# shellcheck source=../../bootstrap-foundation/lib/detect-hardware.sh
. "$BF_LIB/detect-hardware.sh"
detect_hardware
print_hw_summary

# ---------------------------------------------------------------------------
# 2. Verify this node qualifies as PRIMARY
# ---------------------------------------------------------------------------
if [ "$HW_NODE_PROFILE" != primary ]; then
  warn "Node profile is '$HW_NODE_PROFILE', not 'primary'."
  warn "This script is designed for Apple Silicon 32GB+ coordinators."
  warn "Continuing, but consider running install-qnap.sh or install-windows-thin.ps1 instead."
fi

info "Node: $HW_APPLE_CHIP, ${HW_UNIFIED_MB}MB unified, profile=$HW_NODE_PROFILE"

# ---------------------------------------------------------------------------
# 3. Model selection based on HW_INFERENCE_MB
# ---------------------------------------------------------------------------
if   [ "$HW_INFERENCE_MB" -ge 65536 ] 2>/dev/null; then
  PRIMARY_MODELS="llama3.3:70b qwen2.5:32b nomic-embed-text"
elif [ "$HW_INFERENCE_MB" -ge 32768 ] 2>/dev/null; then
  PRIMARY_MODELS="llama3.1:8b qwen2.5:14b nomic-embed-text"
else
  PRIMARY_MODELS="llama3.1:8b qwen2.5:7b nomic-embed-text"
fi
info "Models for this node: $PRIMARY_MODELS"

# ---------------------------------------------------------------------------
# 4. Install Ollama (macOS)
# ---------------------------------------------------------------------------
step "Installing Ollama..."
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
else
  info "Ollama already installed: $(ollama --version 2>/dev/null)"
fi

# Configure Ollama to bind LAN-visible (so thin nodes can reach it)
# macOS: launchd plist
PLIST="$HOME/Library/LaunchAgents/com.local-ai-stack.ollama.plist"
if [ ! -f "$PLIST" ]; then
  step "Writing launchd plist (Ollama on 0.0.0.0:11434)..."
  cat > "$PLIST" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local-ai-stack.ollama</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/bin/ollama</string><string>serve</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>OLLAMA_HOST</key><string>0.0.0.0:11434</string>
    <key>OLLAMA_ORIGINS</key><string>*</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/ollama-primary.log</string>
  <key>StandardErrorPath</key><string>/tmp/ollama-primary.log</string>
</dict></plist>
PLIST_EOF
  launchctl load "$PLIST" 2>/dev/null || true
  info "Ollama launchd plist loaded (LAN-visible on 0.0.0.0:11434)"
fi

# ---------------------------------------------------------------------------
# 5. Pull models
# ---------------------------------------------------------------------------
step "Pulling models: $PRIMARY_MODELS"
for MODEL in $PRIMARY_MODELS; do
  info "Pulling $MODEL..."
  ollama pull "$MODEL" || warn "Failed to pull $MODEL — skip and continue"
done

# ---------------------------------------------------------------------------
# 6. Write hw-profile.json (consumed by cluster/discover.py on startup)
# ---------------------------------------------------------------------------
step "Writing hardware profile to cluster/hw-profile.json..."
mkdir -p "$REPO_ROOT/cluster"
hw_json > "$REPO_ROOT/cluster/hw-profile.json"
info "Hardware profile: $(cat "$REPO_ROOT/cluster/hw-profile.json")"

# ---------------------------------------------------------------------------
# 7. Start Open WebUI + cluster proxy via Docker Compose
# ---------------------------------------------------------------------------
step "Starting Open WebUI + cluster proxy..."
if command -v docker &>/dev/null; then
  cd "$REPO_ROOT"
  docker compose up -d openwebui
else
  warn "Docker not found. Install Docker Desktop for Mac, then run:"
  warn "  cd $REPO_ROOT && docker compose up -d"
fi

# ---------------------------------------------------------------------------
# 8. Start cluster daemon scripts
# ---------------------------------------------------------------------------
step "Starting cluster discover + proxy daemons..."
PID_DIR="$REPO_ROOT/.pids"
mkdir -p "$PID_DIR"

# discover.py
if [ -f "$REPO_ROOT/cluster/discover.py" ]; then
  nohup python3 "$REPO_ROOT/cluster/discover.py" \
    > /tmp/local-ai-discover.log 2>&1 &
  echo $! > "$PID_DIR/discover.pid"
  info "Discovery daemon started (PID $(cat "$PID_DIR/discover.pid"))"
fi

# proxy.py
if [ -f "$REPO_ROOT/cluster/proxy.py" ]; then
  nohup python3 "$REPO_ROOT/cluster/proxy.py" \
    > /tmp/local-ai-proxy.log 2>&1 &
  echo $! > "$PID_DIR/proxy.pid"
  info "Cluster proxy started on :11430 (PID $(cat "$PID_DIR/proxy.pid"))"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
NODE_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 'YOUR-IP')
echo ""
info "============================================================"
info "  PRIMARY coordinator ready!"
info ""
info "  Ollama (LAN)   : http://$NODE_IP:11434"
info "  Cluster proxy  : http://localhost:11430"
info "  Open WebUI     : http://localhost:3000"
info ""
info "  Point thin nodes to:  http://$NODE_IP:11430"
info ""
info "  NEXT: Note MAC for pfsense DHCP reservation:"
info "        $(ifconfig en0 2>/dev/null | awk '/ether/{print $2}' || echo 'see System Settings')"
info "  NEXT: Update cluster/network-map.yaml with reserved IP $NODE_IP"
info "============================================================"
