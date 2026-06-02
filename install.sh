#!/usr/bin/env bash
# =============================================================================
# local-ai-stack — install.sh
# Downstream of: KonradLanz/bootstrap-foundation
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"
COLOR_RESET="\033[0m"

info()  { echo -e "${COLOR_GREEN}[INFO]${COLOR_RESET}  $*"; }
warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Detect OS
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if [ -f /etc/alpine-release ]; then echo "alpine"
      elif grep -qi qnap /proc/version 2>/dev/null || [ -d /etc/config ]; then echo "qnap"
      else echo "linux"
      fi ;;
    *) error "Unsupported OS: $(uname -s)" ;;
  esac
}

OS=$(detect_os)
info "Detected OS: $OS"

# ---------------------------------------------------------------------------
# 1. Check Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  case "$OS" in
    macos)  error "Docker Desktop not found. Install from https://www.docker.com/products/docker-desktop/" ;;
    linux)  warn "Installing Docker..."
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker "$USER" || true ;;
    alpine) apk add --no-cache docker docker-compose && rc-update add docker ;;
    qnap)   error "Install Container Station from QNAP App Center first." ;;
  esac
fi
info "Docker OK: $(docker --version)"

# ---------------------------------------------------------------------------
# 2. Install Ollama
# ---------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
  info "Installing Ollama..."
  case "$OS" in
    macos)  brew install ollama 2>/dev/null || curl -fsSL https://ollama.com/install.sh | sh ;;
    linux|alpine) curl -fsSL https://ollama.com/install.sh | sh ;;
    qnap)   warn "Ollama on QNAP: use LM Studio base URL instead (set LMSTUDIO_BASE_URL in .env)" ;;
  esac
fi

if command -v ollama &>/dev/null; then
  info "Ollama OK: $(ollama --version 2>/dev/null || echo 'installed')"
fi

# ---------------------------------------------------------------------------
# 3. Copy .env if missing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  warn ".env created from .env.example — edit it before proceeding."
  warn "  Minimum: set PERPLEXITY_API_KEY if you want the search bridge."
fi

# ---------------------------------------------------------------------------
# 4. Import existing LM Studio GGUF models into Ollama
# ---------------------------------------------------------------------------
LMSTUDIO_MODEL_DIR="${HOME}/.lmstudio/models"
if [ -d "$LMSTUDIO_MODEL_DIR" ]; then
  info "Found LM Studio model directory: $LMSTUDIO_MODEL_DIR"
  info "Importing GGUF models into Ollama (no re-download)..."
  find "$LMSTUDIO_MODEL_DIR" -name '*.gguf' | while read -r GGUF; do
    MODEL_NAME=$(basename "$GGUF" .gguf | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
    if ollama show "$MODEL_NAME" &>/dev/null 2>&1; then
      info "  Already imported: $MODEL_NAME (skipping)"
    else
      MODELFILE=$(mktemp)
      echo "FROM $GGUF" > "$MODELFILE"
      info "  Importing: $MODEL_NAME"
      ollama create "$MODEL_NAME" -f "$MODELFILE" && rm -f "$MODELFILE"
    fi
  done
else
  warn "LM Studio model directory not found at $LMSTUDIO_MODEL_DIR — skipping import."
  warn "  If using LM Studio directly, set LMSTUDIO_BASE_URL in .env."
fi

# ---------------------------------------------------------------------------
# 5. Pull Python dependencies for tools
# ---------------------------------------------------------------------------
if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
  PIP=$(command -v pip3 || command -v pip)
  info "Installing Python tool dependencies..."
  $PIP install --quiet httpx pyyaml 2>/dev/null || warn "pip install failed — tools may not work standalone."
fi

# ---------------------------------------------------------------------------
# 6. Start Open WebUI via Docker Compose
# ---------------------------------------------------------------------------
info "Starting Open WebUI + Ollama via Docker Compose..."
cd "$SCRIPT_DIR"
docker compose up -d

info ""
info "============================================================"
info "  local-ai-stack is running!"
info "  Open WebUI: http://localhost:3000"
info ""
info "  Next steps:"
info "  1. Open http://localhost:3000 and create your admin account"
info "  2. Go to Settings > Tools and paste the contents of:"
info "       tools/fetch_url.py"
info "       tools/perplexity_search.py"
info "       tools/ipr_filter.py"
info "  3. In Settings > Models, your Ollama models should appear"
info "  4. See docs/IPR-POLICY.md to configure the privacy filter"
info "============================================================"
