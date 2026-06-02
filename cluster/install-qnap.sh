#!/usr/bin/env bash
# =============================================================================
# cluster/install-qnap.sh
# QNAP NAS thin node setup.
# Run via SSH on your QNAP: bash install-qnap.sh
# Requires: Container Station installed, SSH enabled.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[QNAP]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

info "=== local-ai-stack QNAP thin node setup ==="
info "Role: tiny-model local worker + proxy to PRIMARY"

# ---------------------------------------------------------------------------
# 1. Detect QNAP environment
# ---------------------------------------------------------------------------
if [ ! -d /etc/config ] && ! uname -r 2>/dev/null | grep -qi qnap; then
  warn "This does not look like a QNAP. Continuing anyway."
fi

if ! command -v docker &>/dev/null; then
  error "Docker not found. Install Container Station from QNAP App Center first."
fi
info "Docker: $(docker --version)"

# ---------------------------------------------------------------------------
# 2. Install Ollama for Linux (ARM or x86 depending on QNAP model)
# ---------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
  info "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
info "Ollama: $(ollama --version 2>/dev/null || echo installed)"

# ---------------------------------------------------------------------------
# 3. Configure Ollama: bind localhost ONLY (security)
# ---------------------------------------------------------------------------
info "Configuring Ollama (localhost-only on QNAP for security)..."

SVC_FILE="/etc/systemd/system/ollama.service"
if command -v systemctl &>/dev/null && [ -f "$SVC_FILE" ]; then
  # Add OLLAMA_HOST override
  if ! grep -q "OLLAMA_HOST" "$SVC_FILE"; then
    sed -i '/\[Service\]/a Environment="OLLAMA_HOST=127.0.0.1:11434"' "$SVC_FILE"
    systemctl daemon-reload
    systemctl restart ollama
    info "Ollama restricted to localhost"
  fi
else
  warn "systemd not found. Set OLLAMA_HOST=127.0.0.1:11434 manually."
fi

# ---------------------------------------------------------------------------
# 4. Pull tiny model
# ---------------------------------------------------------------------------
info "Pulling tiny model for QNAP (qwen2.5:1.5b)..."
ollama pull qwen2.5:1.5b || warn "Model pull failed — check disk space on /share"

# Optional: pull phi3.5-mini as backup
# ollama pull phi3.5-mini:latest

# ---------------------------------------------------------------------------
# 5. Clone this repo to QNAP (if not already present)
# ---------------------------------------------------------------------------
INSTALL_DIR="/share/homes/admin/local-ai-stack"
if [ ! -d "$INSTALL_DIR" ]; then
  if command -v git &>/dev/null; then
    info "Cloning local-ai-stack to $INSTALL_DIR..."
    git clone https://github.com/KonradLanz/local-ai-stack.git "$INSTALL_DIR"
  else
    warn "git not found. Clone manually: git clone https://github.com/KonradLanz/local-ai-stack.git $INSTALL_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Start Open WebUI (minimal, QNAP-local access only)
# ---------------------------------------------------------------------------
info "Starting Open WebUI (QNAP-local, port 3002)..."
PRIMARY_IP="${PRIMARY_IP:-192.168.1.10}"  # set PRIMARY_IP env var or edit network-map.yaml

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
  docker start local-ai-webui-qnap 2>/dev/null || \
  warn "Open WebUI already running or failed to start."

info ""
info "============================================================"
info "  QNAP thin node ready!"
info ""
info "  Tiny model (local): qwen2.5:1.5b on localhost:11434"
info "  Falls back to PRIMARY at: $PRIMARY_IP:11434"
info "  Open WebUI (QNAP): http://$(hostname -I 2>/dev/null | awk '{print $1}'):3002"
info ""
info "  NEXT: Set PRIMARY_IP in your .env or pass as env var"
info "  NEXT: Add pfsense DHCP reservation for this NAS"
info "  NEXT: Update cluster/network-map.yaml on PRIMARY"
info "============================================================"
