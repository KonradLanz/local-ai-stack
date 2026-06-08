#!/bin/sh
# import-lmstudio-models.sh — part of the Catwalk suite
# Direction: LM Studio → Ollama
#
# Registers single-file GGUFs from LM Studio in Ollama by creating a hard link
# directly into ~/.ollama/models/blobs/ and writing a minimal manifest.
# No data is copied — both tools share the same inode.
#
# SHA256 is cached in a sidecar file (<model>.gguf.sha256) next to each GGUF
# so subsequent runs are instant. LM Studio ignores .sha256 files.
#
# GGUFs are made world-readable (chmod a+r) so the ollama daemon (which may
# run as a different user) can access them via the shared inode.
#
# Multi-part GGUFs and mmproj files are skipped automatically.
#
# Usage:
#   ./catwalk/import-lmstudio-models.sh [options]
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
MANIFEST_ROOT="$OLLAMA_ROOT/manifests/registry.ollama.ai/library"
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Register LM Studio GGUFs in Ollama via hard link (zero extra disk space).
Direction: LM Studio -> Ollama

GGUFs are made world-readable (chmod a+r) so the ollama daemon
can access them even when running as a different user.

Skipped automatically:
  - Multi-part GGUFs  (*-00001-of-*.gguf)
  - Multimodal projectors (mmproj-*.gguf)
  - Models already registered in Ollama

SHA256 is cached in <model>.gguf.sha256 next to each file.

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

# Ensure a file is world-readable. Skipped in dry-run.
ensure_readable() {
  file="$1"
  perms=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")
  # Check if other-read bit (bit 2 of permissions octal) is set
  if [ $(( 0${perms} & 4 )) -eq 0 ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      chmod a+r "$file"
      vlog "  chmod a+r: $file"
    else
      log "  would chmod a+r: $file"
    fi
  else
    vlog "  already world-readable: $file"
  fi
}

# Return SHA256 hash for a file.
# Uses sidecar cache (<file>.sha256) if available; computes and saves it otherwise.
get_sha256() {
  file="$1"
  sidecar="${file}.sha256"

  if [ -f "$sidecar" ]; then
    hash=$(cat "$sidecar" | tr -d '[:space:]')
    vlog "  sha256 (cached): $hash"
    printf '%s' "$hash"
    return
  fi

  log "  computing sha256 (first time, may take a minute for large files)..."
  hash=$(shasum -a 256 "$file" | awk '{print $1}')
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '%s' "$hash" > "$sidecar"
    chmod a+r "$sidecar"
    vlog "  sha256 cached -> $sidecar"
  fi
  printf '%s' "$hash"
}

# Write a minimal Ollama manifest for a model.
write_manifest() {
  manifest_path="$1"
  blob_hash="$2"
  blob_size="$3"
  mkdir -p "$(dirname "$manifest_path")"
  cat > "$manifest_path" <<JSON
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:${blob_hash}","size":256},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:${blob_hash}","size":${blob_size}}]}
JSON
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

[ -d "$LMSTUDIO_ROOT" ] || fail "LM Studio model root not found: $LMSTUDIO_ROOT"
[ -d "$OLLAMA_ROOT" ]   || fail "Ollama root not found: $OLLAMA_ROOT"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BLOB_ROOT"
  mkdir -p "$MANIFEST_ROOT"
fi

TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT HUP INT TERM

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

  count=$((count + 1))

  # Ensure GGUF is world-readable (ollama daemon may run as different user)
  ensure_readable "$gguf"

  # Derive Ollama model tag from directory structure
  rel=${gguf#"$LMSTUDIO_ROOT"/}
  namespace=$(printf '%s' "$rel" | cut -d'/' -f1)
  stem=$(basename "$filename" .gguf)
  model_name=$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  # Check if manifest already exists
  manifest_path="$MANIFEST_ROOT/$model_name/latest"
  if [ -f "$manifest_path" ]; then
    vlog "skip already registered: $model_name"
    skipped=$((skipped + 1))
    continue
  fi

  log "processing: $namespace/$model_name"
  log "  source: $gguf"

  if [ "$DRY_RUN" -eq 1 ]; then
    sidecar="${gguf}.sha256"
    if [ -f "$sidecar" ]; then
      hash=$(cat "$sidecar" | tr -d '[:space:]')
      log "  would hardlink blob: sha256-${hash}"
    else
      log "  would compute sha256 + hardlink blob (no sidecar yet)"
    fi
    log "  would write manifest: $manifest_path"
    imported=$((imported + 1))
    continue
  fi

  # Get SHA256 (sidecar cache or fresh compute)
  hash=$(get_sha256 "$gguf")
  blob_dest="$BLOB_ROOT/sha256-${hash}"

  # Hard link blob (replace copy with hardlink if inode differs)
  if [ -f "$blob_dest" ]; then
    src_inode=$(ls -i "$gguf" | awk '{print $1}')
    dst_inode=$(ls -i "$blob_dest" | awk '{print $1}')
    if [ "$src_inode" = "$dst_inode" ]; then
      vlog "  blob already hardlinked (same inode)"
    else
      log "  replacing copy with hardlink (recovering disk space)..."
      rm -f "$blob_dest"
      ln "$gguf" "$blob_dest"
      log "  hardlinked: $blob_dest"
    fi
  else
    ln "$gguf" "$blob_dest"
    log "  hardlinked: $blob_dest"
  fi

  # Write manifest
  blob_size=$(stat -f%z "$gguf" 2>/dev/null || stat -c%s "$gguf")
  write_manifest "$manifest_path" "$hash" "$blob_size"
  log "  manifest: $manifest_path"
  log "  done: $namespace/$model_name"

  imported=$((imported + 1))

done < "$TMP_LIST"

log ""
log "GGUFs found          : $count"
log "Imported/would import: $imported"
log "Skipped              : $skipped"
