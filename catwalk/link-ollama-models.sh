#!/bin/sh
# link-ollama-models.sh — part of the Catwalk suite
#
# Create symlinks for Ollama GGUF model blobs inside LM Studio's model folder.
# Works on macOS and Linux (POSIX sh, no external dependencies beyond awk/sed/find).
#
# Usage:
#   ./catwalk/link-ollama-models.sh [options]
#
# Options:
#   -n, --dry-run   Show what would be done without changing files
#   -f, --force     Replace existing files or symlinks at destination
#   -v, --verbose   Print extra diagnostics
#   -h, --help      Show this help
#
# Environment:
#   OLLAMA_ROOT     Ollama model store  (default: ~/.ollama/models)
#   LMSTUDIO_ROOT   LM Studio target    (default: ~/.cache/lm-studio/models/ollama)

set -eu

OLLAMA_ROOT=${OLLAMA_ROOT:-"$HOME/.ollama/models"}
LMSTUDIO_ROOT=${LMSTUDIO_ROOT:-"$HOME/.cache/lm-studio/models/ollama"}
DRY_RUN=0
FORCE=0
VERBOSE=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Create symlinks for Ollama GGUF model blobs inside LM Studio's model folder.

Options:
  -n, --dry-run   Show what would be done without changing files
  -f, --force     Replace existing files or symlinks at destination
  -v, --verbose   Print extra diagnostics
  -h, --help      Show this help

Environment:
  OLLAMA_ROOT     Default: ~/.ollama/models
  LMSTUDIO_ROOT   Default: ~/.cache/lm-studio/models/ollama
USAGE
}

log()  { printf '%s\n' "$*"; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" || true; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -f|--force)   FORCE=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[ -d "$OLLAMA_ROOT" ]  || fail "Ollama model root not found: $OLLAMA_ROOT"
MANIFEST_ROOT="$OLLAMA_ROOT/manifests"
BLOB_ROOT="$OLLAMA_ROOT/blobs"
[ -d "$MANIFEST_ROOT" ] || fail "Ollama manifest directory not found: $MANIFEST_ROOT"
[ -d "$BLOB_ROOT" ]     || fail "Ollama blob directory not found: $BLOB_ROOT"

[ "$DRY_RUN" -eq 0 ] && mkdir -p "$LMSTUDIO_ROOT"

TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT HUP INT TERM

find "$MANIFEST_ROOT" -type f > "$TMP_LIST"

count=0
created=0
skipped=0

while IFS= read -r manifest; do
  [ -n "$manifest" ] || continue
  rel=${manifest#"$MANIFEST_ROOT"/}

  blob_digest=$(awk -F '"' '
    /"mediaType"[[:space:]]*:[[:space:]]*"application\/vnd\.ollama\.image\.model"/ {want=1}
    want && /"digest"[[:space:]]*:/ {print $4; exit}
  ' "$manifest")

  if [ -z "$blob_digest" ]; then
    vlog "skip manifest without model digest: $rel"
    skipped=$((skipped + 1))
    continue
  fi

  blob_name=$(printf '%s' "$blob_digest" | sed 's/:/-/g')
  src="$BLOB_ROOT/$blob_name"

  if [ ! -f "$src" ]; then
    vlog "skip missing blob: $src"
    skipped=$((skipped + 1))
    continue
  fi

  dirpart=$(dirname "$rel")
  filepart=$(basename "$rel")
  model_name=$(printf '%s' "$filepart" | sed 's/:/-/g').gguf
  dest_dir="$LMSTUDIO_ROOT/$dirpart"
  dest="$dest_dir/$model_name"
  count=$((count + 1))

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ "$FORCE" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "would replace: $dest -> $src"
      else
        mkdir -p "$dest_dir"
        rm -f "$dest"
        ln -s "$src" "$dest"
        log "replaced: $dest -> $src"
      fi
      created=$((created + 1))
    else
      vlog "skip existing: $dest"
      skipped=$((skipped + 1))
    fi
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would link: $dest -> $src"
  else
    mkdir -p "$dest_dir"
    ln -s "$src" "$dest"
    log "linked: $dest -> $src"
  fi
  created=$((created + 1))

done < "$TMP_LIST"

log ""
log "Manifests processed : $count"
log "Links created/updated: $created"
log "Skipped              : $skipped"
