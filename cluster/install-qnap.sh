#!/usr/bin/env bash
# =============================================================================
# cluster/install-qnap.sh
# QNAP NAS thin node setup.
# Run via SSH on your QNAP: bash install-qnap.sh
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
#
# PREREQUISITES on QNAP:
#   - SSH enabled  (Control Panel > Network Services > Telnet/SSH)
#   - Container Station installed from App Center (provides Docker)
#     OR: script will run Ollama natively without Docker if needed.
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[QNAP]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${RESET}  $*"; }

info "=== local-ai-stack QNAP thin node setup ==="
info "Role: tiny-model local worker + proxy to PRIMARY"

# ---------------------------------------------------------------------------
# FIX 1: Reliable QNAP detection
# QNAP does NOT put 'qnap' in uname -r. Detect by filesystem layout.
# ---------------------------------------------------------------------------
IS_QNAP=false
if [ -f /etc/init.d/functions.sh ] || \
   [ -d /share/CACHEDEV1_DATA ] || \
   [ -d /etc/config ] || \
   command -v qpkg_cli &>/dev/null 2>&1; then
  IS_QNAP=true
  info "QNAP environment detected."
else
  warn "QNAP markers not found — may be a non-QNAP Linux. Continuing."
fi

# ---------------------------------------------------------------------------
# FIX 2: Docker check — guide instead of hard-stop
# ---------------------------------------------------------------------------
HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  HAS_DOCKER=true
  info "Docker available: $(docker --version)"
else
  warn "Docker not available (or not running)."
  if [ "$IS_QNAP" = true ]; then
    warn "  To enable Docker:"
    warn "  1. Open QNAP App Center"
    warn "  2. Search for 'Container Station' and install it"
    warn "  3. Wait for Container Station to fully start"
    warn "  4. Re-run this script"
    warn "  Continuing without Docker — Ollama will run natively."
    warn "  Open WebUI step will be skipped until Docker is available."
  fi
  # Don't exit — Ollama can run fine without Docker
fi

# ---------------------------------------------------------------------------
# 2. Install Ollama (native Linux binary, works on QNAP without Docker)
# ---------------------------------------------------------------------------
step "Installing Ollama..."
if ! command -v ollama &>/dev/null; then
  # QNAP uses /usr/local/bin or /opt/bin depending on entware
  # The official installer handles this
  info "Downloading Ollama installer..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'installed')"
fi

# Ensure ollama is on PATH for this session
export PATH="$PATH:/usr/local/bin:/opt/bin"

if ! command -v ollama &>/dev/null; then
  error "Ollama install failed. Check: https://github.com/ollama/ollama/releases"
  error "Download the linux-arm64 or linux-amd64 binary manually to /usr/local/bin/ollama"
  exit 1
fi
info "Ollama: $(ollama --version 2>/dev/null || echo installed)"

# ---------------------------------------------------------------------------
# 3. Start Ollama (bound to localhost only for security)
# ---------------------------------------------------------------------------
step "Starting Ollama (localhost-only)..."
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_ORIGINS="*"

# Check if already running
if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
  info "Ollama already running on :11434"
else
  nohup env OLLAMA_HOST=127.0.0.1:11434 OLLAMA_ORIGINS='*' ollama serve \
    > /tmp/ollama-qnap.log 2>&1 &
  OLLAMA_PID=$!
  echo $OLLAMA_PID > /tmp/ollama-qnap.pid
  info "Ollama started (PID $OLLAMA_PID), waiting for readiness..."
  for i in $(seq 1 15); do
    sleep 1
    if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
      info "Ollama ready."
      break
    fi
    [ "$i" -eq 15 ] && warn "Ollama slow to start — check /tmp/ollama-qnap.log"
  done
fi

# Persist across reboots: write to QNAP autorun if available
AUTORUN="/etc/config/autorun.sh"
if [ -f "$AUTORUN" ] || [ "$IS_QNAP" = true ]; then
  if ! grep -q 'ollama serve' "$AUTORUN" 2>/dev/null; then
    info "Adding Ollama to QNAP autorun ($AUTORUN)..."
    cat >> "$AUTORUN" << 'AUTORUN_ENTRY'

# local-ai-stack: start Ollama on boot
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_ORIGINS='*'
nohup ollama serve > /tmp/ollama-qnap.log 2>&1 &
AUTORUN_ENTRY
    chmod +x "$AUTORUN"
    info "Autorun configured."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Pull tiny model
# ---------------------------------------------------------------------------
step "Pulling tiny model: qwen2.5:1.5b (~1GB)..."
info "This may take a few minutes depending on your WAN connection."
ollama pull qwen2.5:1.5b || warn "Model pull failed — check disk space on /share and retry: ollama pull qwen2.5:1.5b"

# ---------------------------------------------------------------------------
# 5. Install Python deps for ipr_filter (optional, best-effort)
# ---------------------------------------------------------------------------
step "Installing Python dependencies..."
for PIP in pip3 pip; do
  if command -v "$PIP" &>/dev/null; then
    "$PIP" install --quiet pyyaml httpx 2>/dev/null && \
      info "Python deps installed via $PIP" && break
  fi
done
# Entware pip if available
if [ -x /opt/bin/pip3 ]; then
  /opt/bin/pip3 install --quiet pyyaml httpx 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 6. Clone repo to QNAP
# ---------------------------------------------------------------------------
INSTALL_DIR="/share/homes/admin/local-ai-stack"
if [ ! -d "$INSTALL_DIR" ]; then
  if command -v git &>/dev/null; then
    step "Cloning local-ai-stack to $INSTALL_DIR..."
    git clone https://github.com/KonradLanz/local-ai-stack.git "$INSTALL_DIR"
  else
    warn "git not found. Install Entware git or clone manually:"
    warn "  git clone https://github.com/KonradLanz/local-ai-stack.git $INSTALL_DIR"
  fi
else
  info "Repo already at $INSTALL_DIR"
fi

# ---------------------------------------------------------------------------
# 7. Start Open WebUI (only if Docker available)
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
    docker start local-ai-webui-qnap 2>/dev/null || \
    warn "Open WebUI already running or failed to start."
  info "Open WebUI: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'QNAP-IP'):3002"
else
  warn "Docker not available — Open WebUI skipped."
  warn "Install Container Station and re-run to enable the Web UI."
  warn "You can still use Ollama via CLI: ollama run qwen2.5:1.5b"
  warn "Or access PRIMARY's Web UI at: http://$PRIMARY_IP:3000"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR-QNAP-IP')
echo ""
info "============================================================"
info "  QNAP thin node ready!"
info ""
info "  Ollama (local): http://127.0.0.1:11434"
info "  Model loaded  : qwen2.5:1.5b"
info "  PRIMARY node  : $PRIMARY_IP:11434"
[ "$HAS_DOCKER" = true ] && info "  Open WebUI    : http://$NAS_IP:3002"
info ""
info "  CLI test      : ollama run qwen2.5:1.5b"
info ""
info "  NEXT: Note MAC for pfsense DHCP reservation:"
info "        $(ip link show 2>/dev/null | awk '/ether/{print $2}' | head -1 || echo 'see Control Panel > Network')"
info "  NEXT: Reserve IP $NAS_IP for this MAC in pfsense"
info "  NEXT: Update cluster/network-map.yaml on PRIMARY"
info "============================================================"
