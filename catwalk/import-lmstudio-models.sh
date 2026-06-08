#!/bin/sh
# import-lmstudio-models.sh — part of the Catwalk suite
# Direction: LM Studio → Ollama
#
# Imports single-file GGUF models from LM Studio into Ollama via 'ollama create'.
# Multi-part GGUFs (00001-of-XXXXX) and mmproj files are skipped automatically.
#
# Usage:
#   ./catwalk/import-lmstudio-models.sh [options]
#
# Options:
#   -n, --dry-run   Show what would be done without importing
#   -v, --verbose   Print extra diagnostics
#   -h, --help      Show this help
#
# Environment:
#   LMSTUDIO_ROOT   LM Studio models    (default: ~/.lmstudio/models)

set -eu

LMSTUDIO_ROOT=${LMSTUDIO_ROOT:-"$HOME/.lmstudio/models"}
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Import single-file GGUF models from LM Studio into Ollama.
Direction: LM Studio -> Ollama

Skipped automatically:
  - Multi-part GGUFs  (*-00001-of-*.gguf)
  - Multimodal projectors (mmproj-*.gguf)
  - Models already known to Ollama

Options:
  -n, --dry-run   Show what would be done without importing
  -v, --verbose   Print extra diagnostics
  -h, --help      Show this help

Environment:
  LMSTUDIO_ROOT   Default: ~/.lmstudio/models
USAGE
}

log()  { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" || true; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[ -d "$LMSTUDIO_ROOT" ] || fail "LM Studio model root not found: $LMSTUDIO_ROOT"
command -v ollama >/dev/null 2>&1 || fail "ollama not found in PATH"

TMP_LIST="$(mktemp)"
TMP_MODELFILE="$(mktemp)"
trap 'rm -f "$TMP_LIST" "$TMP_MODELFILE"' EXIT HUP INT TERM

find "$LMSTUDIO_ROOT" -type f -name '*.gguf' \
  -not -name '.DS_Store' \
  -not -name '._*' \
  > "$TMP_LIST"

count=0
imported=0
skipped=0

while IFS= read -r gguf; do
  [ -n "$gguf" ] || continue

  filename=$(basename "$gguf")

  # Skip multimodal projectors
  case "$filename" in
    mmproj-*)
      vlog "skip mmproj: $filename"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  # Skip multi-part GGUFs (e.g. model-00001-of-00003.gguf)
  case "$filename" in
    *-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]*)
      vlog "skip multi-part: $filename"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  # Derive a clean Ollama model name from the directory structure
  # e.g. ~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-GGUF/gemma-4-31B-it-Q4_K_M.gguf
  # -> lmstudio-community/gemma-4-31B-it-Q4_K_M
  rel=${gguf#"$LMSTUDIO_ROOT"/}
  namespace=$(printf '%s' "$rel" | cut -d'/' -f1)
  stem=$(basename "$filename" .gguf)
  # lowercase and replace spaces/underscores with hyphens for Ollama naming
  model_tag=$(printf '%s/%s' "$namespace" "$stem" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  count=$((count + 1))

  # Check if already imported
  if ollama show "$model_tag" >/dev/null 2>&1; then
    vlog "skip already in Ollama: $model_tag"
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would import: $model_tag  ($filename)"
    imported=$((imported + 1))
    continue
  fi

  log "importing: $model_tag  ($filename)"
  printf 'FROM %s\n' "$gguf" > "$TMP_MODELFILE"
  if ollama create "$model_tag" -f "$TMP_MODELFILE"; then
    log "  done: $model_tag"
    imported=$((imported + 1))
  else
    log "  FAILED: $model_tag" >&2
    skipped=$((skipped + 1))
  fi

done < "$TMP_LIST"

log ""
log "GGUFs found          : $count"
log "Imported/would import: $imported"
log "Skipped              : $skipped"
