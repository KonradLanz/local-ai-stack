#!/usr/bin/env bash
# =============================================================================
# cluster/install-qnap.sh
# QNAP NAS thin node setup.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[QNAP]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${RESET}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Load shared detection from bootstrap-foundation
# ---------------------------------------------------------------------------
step "Loading OS + hardware detection..."

BF_LIB="${BOOTSTRAP_FOUNDATION:-$(cd "$REPO_ROOT/../bootstrap-foundation" 2>/dev/null && pwd || echo '')}/lib"

if [ ! -d "$BF_LIB" ]; then
  warn "bootstrap-foundation not found — cloning..."
  INSTALL_DIR="/share/homes/admin"
  mkdir -p "$INSTALL_DIR"
  git clone https://github.com/KonradLanz/bootstrap-foundation.git \
    "$INSTALL_DIR/bootstrap-foundation" 2>/dev/null || true
  BF_LIB="$INSTALL_DIR/bootstrap-foundation/lib"
fi

if [ -f "$BF_LIB/detect-os.sh" ]; then
  . "$BF_LIB/detect-os.sh" && detect_os
  . "$BF_LIB/detect-hardware.sh" && detect_hardware
  print_hw_summary
  info "Profile auto-detected: $HW_NODE_PROFILE"
else
  warn "Could not load detection libs — applying qnap profile defaults."
  HW_NODE_PROFILE=qnap
  HW_RAM_MB=24576
  HW_INFERENCE_MB=8192
fi

# Force qnap profile on QNAP hardware (bootstrap-foundation already sets this,
# but guard in case detection libs were missing)
[ "$HW_NODE_PROFILE" != qnap ] && {
  warn "Profile is '$HW_NODE_PROFILE' — forcing qnap for this NAS."
  HW_NODE_PROFILE=qnap
}

# ---------------------------------------------------------------------------
# 2. Docker check — non-fatal, guide to Container Station
# ---------------------------------------------------------------------------
HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  HAS_DOCKER=true
  info "Docker: $(docker --version)"
else
  warn "Docker not available. To enable:"
  warn "  1. Open QNAP App Center"
  warn "  2. Search 'Container Station' → Install"
  warn "  3. Wait for it to fully start, then re-run this script"
  warn "  Continuing without Docker — Ollama will run natively."
fi

# ---------------------------------------------------------------------------
# 3. Install Ollama
# ---------------------------------------------------------------------------
step "Installing Ollama..."
export PATH="$PATH:/usr/local/bin:/opt/bin"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

# ---------------------------------------------------------------------------
# 4. Start Ollama (localhost-only)
# ---------------------------------------------------------------------------
step "Starting Ollama on localhost..."
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_ORIGINS='*'

if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
  nohup env OLLAMA_HOST=127.0.0.1:11434 OLLAMA_ORIGINS='*' ollama serve \
    > /tmp/ollama-qnap.log 2>&1 &
  for i in $(seq 1 15); do
    sleep 1
    curl -sf http://127.0.0.1:11434/api/tags &>/dev/null && break
  done
fi

# Persist across reboots
AUTORUN="/etc/config/autorun.sh"
if [ -f "$AUTORUN" ] && ! grep -q 'ollama serve' "$AUTORUN"; then
  cat >> "$AUTORUN" << 'AE'

# local-ai-stack: start Ollama on boot
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_ORIGINS='*'
nohup ollama serve > /tmp/ollama-qnap.log 2>&1 &
AE
  chmod +x "$AUTORUN"
fi

# ---------------------------------------------------------------------------
# 5. Pull model sized to HW_INFERENCE_MB
# ---------------------------------------------------------------------------
step "Selecting model for HW_INFERENCE_MB=${HW_INFERENCE_MB}MB..."
if   [ "${HW_INFERENCE_MB:-0}" -ge 8192 ] 2>/dev/null; then
  QNAP_MODEL=qwen2.5:3b
elif [ "${HW_INFERENCE_MB:-0}" -ge 4096 ] 2>/dev/null; then
  QNAP_MODEL=qwen2.5:1.5b
else
  QNAP_MODEL=qwen2.5:0.5b
fi
info "Pulling $QNAP_MODEL..."
ollama pull "$QNAP_MODEL" || warn "Pull failed — check disk space on /share"

# ---------------------------------------------------------------------------
# 6. Write hw-profile.json
# ---------------------------------------------------------------------------
mkdir -p "$REPO_ROOT/cluster"
if command -v hw_json &>/dev/null; then
  hw_json > "$REPO_ROOT/cluster/hw-profile.json"
fi

# ---------------------------------------------------------------------------
# 7. Open WebUI (only if Docker available)
# ---------------------------------------------------------------------------
PRIMARY_IP="${PRIMARY_IP:-192.168.1.10}"

if [ "$HAS_DOCKER" = true ]; then
  step "Starting Open WebUI (port 3002)..."
  docker run -d \
    --name local-ai-webui-qnap \
    --restart unless-stopped \
    -p 3002:8080 \
    -e OLLAMA_BASE_URL="http://host.docker.internal:11434" \
    -e OPENAI_API_BASE_URL="http://$PRIMARY_IP:11434/v1" \
    -e OPENAI_API_KEY="local" \
    -e WEBUI_NAME="local-ai-QNAP" \
    -v local-ai-qnap-data:/app/backend/data \
    --add-host="host.docker.internal:host-gateway" \
    ghcr.io/open-webui/open-webui:main 2>/dev/null || \
    docker start local-ai-webui-qnap 2>/dev/null || true
else
  warn "Docker not available — Web UI skipped."
  warn "Access PRIMARY's Web UI at: http://$PRIMARY_IP:3000"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR-QNAP-IP')
NAS_MAC=$(ip link show 2>/dev/null | awk '/ether/{print $2}' | head -1 || echo 'see Control Panel')
echo ""
info "============================================================"
info "  QNAP thin node ready!"
info "  Model         : $QNAP_MODEL (on localhost:11434)"
info "  Inference RAM : ${HW_INFERENCE_MB}MB"
info "  PRIMARY       : $PRIMARY_IP:11434"
[ "$HAS_DOCKER" = true ] && info "  Open WebUI    : http://$NAS_IP:3002"
info ""
info "  pfsense DHCP reservation:"
info "    MAC: $NAS_MAC"
info "    IP:  $NAS_IP (suggest reserving this)"
info "============================================================"
