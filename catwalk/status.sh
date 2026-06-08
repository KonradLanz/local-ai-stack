#!/bin/sh
# status.sh — part of the Catwalk suite
#
# Shows a unified inventory of all models across LM Studio and Ollama.
# For each model, reports:
#   - which tool(s) have it
#   - file size
#   - SHA256 (from sidecar cache if available, else from blob name for Ollama)
#   - inode status: hardlinked / copy / unique
#
# No files are created or modified.
#
# Usage:
#   ./catwalk/status.sh [options]
#
# Options:
#   -v, --verbose   Print blob paths
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
VERBOSE=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Unified model inventory across LM Studio and Ollama.
Reports size, SHA256, and hardlink/copy/unique status.

Legend:
  [HL] hardlinked   — same inode, zero extra disk space
  [CP] copy         — same sha256, different inode (wasted space)
  [LM] LM Studio only
  [OL] Ollama only

Options:
  -v, --verbose   Print full blob/file paths
  -h, --help      Show this help

Environment:
  LMSTUDIO_ROOT   Default: ~/.lmstudio/models
  OLLAMA_ROOT     Default: ~/.ollama/models
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

hr() { printf '%s\n' '------------------------------------------------------------------------'; }

human_size() {
  bytes="$1"
  if   [ "$bytes" -ge 1073741824 ]; then printf '%d GB' $(( bytes / 1073741824 ))
  elif [ "$bytes" -ge 1048576 ];    then printf '%d MB' $(( bytes / 1048576 ))
  elif [ "$bytes" -ge 1024 ];       then printf '%d KB' $(( bytes / 1024 ))
  else printf '%d B' "$bytes"
  fi
}

# ---- Collect LM Studio GGUFs ------------------------------------------------

TMP_LM="$(mktemp)"
trap 'rm -f "$TMP_LM"' EXIT HUP INT TERM

printf '\n'
hr
printf 'LM Studio models: %s\n' "$LMSTUDIO_ROOT"
hr

lm_total_bytes=0
lm_count=0

if [ ! -d "$LMSTUDIO_ROOT" ]; then
  printf '  (directory not found)\n'
else
  find "$LMSTUDIO_ROOT" -type f -name '*.gguf' \
    -not -name '.DS_Store' -not -name '._*' | sort | while IFS= read -r gguf; do

    filename=$(basename "$gguf")
    case "$filename" in mmproj-*) continue ;; esac
    case "$filename" in *-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]*) continue ;; esac

    size=$(stat -f%z "$gguf" 2>/dev/null || stat -c%s "$gguf")
    inode=$(ls -i "$gguf" | awk '{print $1}')
    nlink=$(ls -l "$gguf" | awk '{print $2}')

    # Try sidecar for hash
    sidecar="${gguf}.sha256"
    if [ -f "$sidecar" ]; then
      hash=$(cat "$sidecar" | tr -d '[:space:]')
      hash_src="sidecar"
    else
      hash="(run import script to cache)"
      hash_src="none"
    fi

    sz=$(human_size "$size")
    printf '  %-55s  %6s  links=%s  inode=%s\n' "$filename" "$sz" "$nlink" "$inode"
    if [ "$hash_src" = "sidecar" ]; then
      printf '    sha256: %s\n' "$hash"
    else
      printf '    sha256: %s\n' "$hash"
    fi
    [ "$VERBOSE" -eq 1 ] && printf '    path:   %s\n' "$gguf"

    # Save to tempfile for cross-reference: inode|hash|size|name
    printf '%s|%s|%s|%s\n' "$inode" "$hash" "$size" "$filename" >> "$TMP_LM"
  done
fi

# ---- Collect Ollama blobs ---------------------------------------------------

printf '\n'
hr
printf 'Ollama models: %s\n' "$MANIFEST_ROOT"
hr

if [ ! -d "$MANIFEST_ROOT" ]; then
  printf '  (directory not found)\n'
else
  find "$MANIFEST_ROOT" -type f | sort | while IFS= read -r manifest; do

    rel=${manifest#"$MANIFEST_ROOT"/}
    tag=$(basename "$rel")
    name=$(basename "$(dirname "$rel")")
    ns=$(basename "$(dirname "$(dirname "$rel")")") 2>/dev/null || ns="library"

    if [ "$ns" = "library" ]; then model_label="${name}:${tag}"
    else model_label="${ns}/${name}:${tag}"
    fi

    # Extract model blob hash from manifest (no jq)
    hash=$(grep -o '"digest":"sha256:[a-f0-9]*"' "$manifest" \
      | head -1 | grep -o '[a-f0-9]\{64\}') || hash=""

    [ -z "$hash" ] && { printf '  %-40s  (no model layer)\n' "$model_label"; continue; }

    blob="$BLOB_ROOT/sha256-${hash}"
    if [ ! -f "$blob" ]; then
      printf '  %-40s  BLOB MISSING\n' "$model_label"
      continue
    fi

    size=$(stat -f%z "$blob" 2>/dev/null || stat -c%s "$blob")
    inode=$(ls -i "$blob" | awk '{print $1}')
    nlink=$(ls -l "$blob" | awk '{print $2}')
    sz=$(human_size "$size")

    printf '  %-55s  %6s  links=%s  inode=%s\n' "$model_label" "$sz" "$nlink" "$inode"
    printf '    sha256: %s\n' "$hash"
    [ "$VERBOSE" -eq 1 ] && printf '    blob:   %s\n' "$blob"

    # Cross-reference with LM Studio tempfile
    if [ -s "$TMP_LM" ]; then
      lm_inode=$(grep "^${inode}|" "$TMP_LM" | head -1 | cut -d'|' -f1)
      lm_hash=$(grep "|${hash}|" "$TMP_LM" | head -1 | cut -d'|' -f2)

      if [ -n "$lm_inode" ] && [ "$lm_inode" = "$inode" ]; then
        lm_name=$(grep "^${inode}|" "$TMP_LM" | head -1 | cut -d'|' -f4)
        printf '    [HL] hardlinked with LM Studio: %s\n' "$lm_name"
      elif [ -n "$lm_hash" ]; then
        lm_name=$(grep "|${hash}|" "$TMP_LM" | head -1 | cut -d'|' -f4)
        printf '    [CP] same sha256 as LM Studio (COPY, wasted space): %s\n' "$lm_name"
      else
        printf '    [OL] Ollama only\n'
      fi
    else
      printf '    [OL] Ollama only (no LM Studio sidecar data available)\n'
    fi

  done
fi

printf '\n'
hr
printf 'Tip: run import-lmstudio-models.sh to link LM Studio -> Ollama\n'
printf '     run import-ollama-models-2-lm-studio.sh to link Ollama -> LM Studio\n'
hr
printf '\n'
