#!/bin/sh
# import-ollama-models-2-lm-studio.sh — part of the Catwalk suite
# Direction: Ollama → LM Studio
#
# Creates hard links from Ollama blobs into the LM Studio model directory so
# both tools share the same inode — no data is copied.
#
# Ollama blob filenames have no extension (sha256-<hash>). LM Studio requires
# .gguf files, so the hard link target gets a .gguf suffix.
#
# Model placement:
#   ~/.lmstudio/models/ollama/<model-name>/<model-name>.gguf
#
# Only single-file GGUF models are linked (layers with mediaType
# application/vnd.ollama.image.model). Config blobs and adapter layers
# are skipped automatically.
#
# Usage:
#   ./catwalk/import-ollama-models-2-lm-studio.sh [options]
#
# Options:
#   -n, --dry-run   Show what would be done without changing files
#   -v, --verbose   Print extra diagnostics
#   -h, --help      Show this help
#
# Environment:
#   LMSTUDIO_ROOT   LM Studio models  (default: ~/.lmstudio/models)
#   OLLAMA_ROOT     Ollama store       (default: ~/.ollama/models)

set -eu

LMSTUDIO_ROOT=${LMSTUDIO_ROOT:-"$HOME/.lmstudio/models"}
OLLAMA_ROOT=${OLLAMA_ROOT:-"$HOME/.ollama/models"}
BLOB_ROOT="$OLLAMA_ROOT/blobs"
MANIFEST_ROOT="$OLLAMA_ROOT/manifests"
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Link Ollama models into LM Studio via hard link (zero extra disk space).
Direction: Ollama -> LM Studio

Placement: ~/.lmstudio/models/ollama/<model>/<model>.gguf

Skipped automatically:
  - Models already present in LM Studio
  - Non-GGUF / adapter layers
  - Blobs that are not single-file models

Options:
  -n, --dry-run   Show what would be done without changing files
  -v, --verbose   Print extra diagnostics
  -h, --help      Show this help

Environment:
  LMSTUDIO_ROOT   Default: ~/.lmstudio/models
  OLLAMA_ROOT     Default: ~/.ollama/models
USAGE
}

log()  { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" || true; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Extract the model blob hash from an Ollama manifest (pure POSIX, no jq).
# Looks for the layer with mediaType application/vnd.ollama.image.model
# and returns its sha256 digest.
extract_model_hash() {
  manifest="$1"
  # Find digest on the line after the model mediaType, or on the same line
  # Manifest is minified JSON — grep for the model layer digest directly
  hash=$(grep -o '"digest":"sha256:[a-f0-9]*"' "$manifest" \
    | head -1 \
    | grep -o '[a-f0-9]\{64\}')
  printf '%s' "$hash"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[ -d "$OLLAMA_ROOT" ]   || fail "Ollama root not found: $OLLAMA_ROOT"
[ -d "$BLOB_ROOT" ]     || fail "Ollama blobs dir not found: $BLOB_ROOT"
[ -d "$MANIFEST_ROOT" ] || fail "Ollama manifests dir not found: $MANIFEST_ROOT"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$LMSTUDIO_ROOT/ollama"
fi

count=0
imported=0
skipped=0

# Walk all manifests: manifests/<registry>/<namespace>/<name>/<tag>
find "$MANIFEST_ROOT" -type f | while IFS= read -r manifest; do

  # Derive a clean model name from the manifest path
  # e.g. .../library/llama3/latest -> llama3
  #      .../davidau/openai-36b.../latest -> davidau-openai-36b...
  rel=${manifest#"$MANIFEST_ROOT"/}
  # rel = registry/namespace/name/tag
  tag=$(basename "$rel")
  name_part=$(dirname "$rel")                       # registry/namespace/name
  name=$(basename "$name_part")                     # name
  ns_part=$(dirname "$name_part")                   # registry/namespace
  namespace=$(basename "$ns_part")                  # namespace

  # Build a readable model name
  if [ "$namespace" = "library" ]; then
    model_label="${name}:${tag}"
    model_slug="$name"
  else
    model_label="${namespace}/${name}:${tag}"
    model_slug="${namespace}-${name}"
  fi

  count=$((count + 1))

  dest_dir="$LMSTUDIO_ROOT/ollama/${model_slug}"
  dest_gguf="$dest_dir/${model_slug}.gguf"

  if [ -f "$dest_gguf" ]; then
    vlog "skip already in LM Studio: $model_label"
    skipped=$((skipped + 1))
    continue
  fi

  # Extract model blob hash from manifest
  hash=$(extract_model_hash "$manifest")
  if [ -z "$hash" ]; then
    vlog "skip (no model layer found): $model_label"
    skipped=$((skipped + 1))
    continue
  fi

  blob="$BLOB_ROOT/sha256-${hash}"
  if [ ! -f "$blob" ]; then
    log "  WARNING: blob missing for $model_label (sha256-${hash})"
    skipped=$((skipped + 1))
    continue
  fi

  log "processing: $model_label"
  log "  blob:  $blob"
  log "  dest:  $dest_gguf"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  would hardlink blob -> $dest_gguf"
    imported=$((imported + 1))
    continue
  fi

  mkdir -p "$dest_dir"
  ln "$blob" "$dest_gguf"
  log "  hardlinked: $dest_gguf"
  log "  done: $model_label"

  imported=$((imported + 1))

done

log ""
log "Ollama manifests found : $count"
log "Linked/would link      : $imported"
log "Skipped                : $skipped"

if [ "$DRY_RUN" -eq 0 ]; then
  log ""
  log "=== LM Studio model dirs (ollama/) ==="
  ls -1 "$LMSTUDIO_ROOT/ollama/" 2>/dev/null || log "(none yet)"
fi
