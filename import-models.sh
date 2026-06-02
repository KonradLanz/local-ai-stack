#!/usr/bin/env bash
# =============================================================================
# import-models.sh
# Imports existing LM Studio GGUF models into Ollama.
# Run this if you already have install.sh done and just want to re-import.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

LMSTUDIO_DIR="${1:-${HOME}/.lmstudio/models}"

if [ ! -d "$LMSTUDIO_DIR" ]; then
  warn "LM Studio model directory not found: $LMSTUDIO_DIR"
  warn "Usage: bash import-models.sh [path/to/models]"
  exit 0
fi

if ! command -v ollama &>/dev/null; then
  echo "Ollama not found. Run install.sh first."
  exit 1
fi

info "Scanning: $LMSTUDIO_DIR"
COUNT=0

find "$LMSTUDIO_DIR" -name '*.gguf' | sort | while read -r GGUF; do
  # Derive a clean model name from filename
  MODEL_NAME=$(basename "$GGUF" .gguf | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/--*/-/g')
  SIZE=$(du -sh "$GGUF" 2>/dev/null | cut -f1)

  if ollama show "$MODEL_NAME" &>/dev/null 2>&1; then
    info "  [skip] $MODEL_NAME ($SIZE) — already in Ollama"
  else
    info "  [import] $MODEL_NAME ($SIZE)"
    MODELFILE=$(mktemp)
    echo "FROM $GGUF" > "$MODELFILE"
    if ollama create "$MODEL_NAME" -f "$MODELFILE"; then
      info "    ✓ Imported: $MODEL_NAME"
      COUNT=$((COUNT + 1))
    else
      warn "    ✗ Failed: $MODEL_NAME"
    fi
    rm -f "$MODELFILE"
  fi
done

info ""
info "Done. Run 'ollama list' to see all available models."
