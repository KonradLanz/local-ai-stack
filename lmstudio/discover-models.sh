#!/usr/bin/env bash
# =============================================================================
# lmstudio/discover-models.sh
# Scans well-known LM Studio model directories on macOS/Linux,
# prints a formatted list, and optionally writes lmstudio/models.json
# for use by discover.py and the cluster proxy.
#
# Usage:
#   bash lmstudio/discover-models.sh              # print table
#   bash lmstudio/discover-models.sh --json       # write lmstudio/models.json
#   bash lmstudio/discover-models.sh --test       # quick OpenAI-compat API test
#
# LM Studio local server must be running for --test:
#   Default: http://localhost:1234
#   Set LMS_HOST=http://192.168.1.62:1234 to point at another machine.
#   NOTE: remote IP only works if LM Studio binds to 0.0.0.0 (see README).
#
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_JSON="$SCRIPT_DIR/models.json"
LMS_HOST="${LMS_HOST:-http://localhost:1234}"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"
DIM="\033[2m"; BOLD="\033[1m"; RESET="\033[0m"

# ---------------------------------------------------------------------------
# Well-known LM Studio model directories (macOS + Linux)
# LM Studio stores models under ~/.lmstudio/models/ as of v0.3+
# Older versions used ~/Library/Application Support/ on macOS
# ---------------------------------------------------------------------------
candidate_dirs() {
  echo "$HOME/.lmstudio/models"                                              # v0.3+ cross-platform
  echo "$HOME/Library/Application Support/LM-Studio/models"                 # macOS legacy
  echo "$HOME/Library/Caches/lm-studio/models"                              # macOS cache
  echo "$HOME/.cache/lm-studio/models"                                      # Linux
  echo "$HOME/.local/share/lm-studio/models"                                # Linux alt
  # Custom path from LM Studio config if present
  local cfg="$HOME/.lmstudio/config.json"
  if [ -f "$cfg" ] && command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    d = json.load(open('$cfg'))
    p = d.get('modelsDir') or d.get('models_dir') or d.get('modelDirectory')
    if p: print(p)
except: pass
" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Scan model files
# ---------------------------------------------------------------------------
scan_models() {
  local found=()
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      found+=("$f")
    done < <(find "$dir" -maxdepth 4 -type f \( \
      -name "*.gguf" -o -name "*.safetensors" -o \
      -name "*.bin" -o -name "*.ggml" \) \
      -not -path "*/blobs/*" \
      -print0 2>/dev/null)
  done < <(candidate_dirs)

  local seen=()
  for f in "${found[@]:-}"; do
    [[ " ${seen[*]:-} " == *" $f "* ]] && continue
    seen+=("$f")
    echo "$f"
  done
}

# ---------------------------------------------------------------------------
# Format bytes
# ---------------------------------------------------------------------------
fmt_size() {
  local bytes="$1"
  if   [ "$bytes" -ge 1073741824 ]; then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif [ "$bytes" -ge 1048576 ];    then printf "%.0f MB" "$(echo "scale=0; $bytes/1048576" | bc)"
  else printf "%d KB" $((bytes / 1024))
  fi
}

# ---------------------------------------------------------------------------
# Main: scan + print
# ---------------------------------------------------------------------------
cmd_list() {
  echo
  echo -e "${BOLD}LM Studio Model Discovery${RESET}"
  echo -e "${DIM}Scanning: $(candidate_dirs | tr '\n' '  ')${RESET}"
  echo

  local count=0 total_bytes=0
  local json_entries="[]"

  while IFS= read -r filepath; do
    [ -f "$filepath" ] || continue
    local filename; filename=$(basename "$filepath")
    local size; size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
    local size_fmt; size_fmt=$(fmt_size "$size")
    local model_name; model_name=$(echo "$filepath" | sed -E \
      's|.*/models/([^/]+/[^/]+)/.*|\1|;s|.*/models/([^/]+)/[^/]+$|\1|')

    printf "  ${CYAN}%-50s${RESET}  %8s  ${DIM}%s${RESET}\n" \
      "$model_name" "$size_fmt" "$filename"

    count=$((count + 1))
    total_bytes=$((total_bytes + size))

    json_entries=$(python3 -c "
import json, sys
entries = json.loads(sys.argv[1])
entries.append({'name': sys.argv[2], 'file': sys.argv[3], 'path': sys.argv[4], 'size_bytes': int(sys.argv[5])})
print(json.dumps(entries))
" "$json_entries" "$model_name" "$filename" "$filepath" "$size" 2>/dev/null || echo "$json_entries")

  done < <(scan_models)

  echo
  if [ "$count" -eq 0 ]; then
    echo -e "  ${YELLOW}No models found.${RESET}"
    echo -e "  ${DIM}Open LM Studio and download a model, or check your models directory.${RESET}"
  else
    echo -e "  ${GREEN}$count model(s) found${RESET}  ($(fmt_size "$total_bytes") total)"
  fi
  echo

  # Write JSON to a temp file so cmd_list output is clean (avoids macOS head -n -1 issue)
  echo "$json_entries" > "${TMPDIR:-/tmp}/lms-models-$$.json"
}

# ---------------------------------------------------------------------------
# Write models.json
# ---------------------------------------------------------------------------
cmd_json() {
  cmd_list
  local tmp="${TMPDIR:-/tmp}/lms-models-$$.json"
  [ -f "$tmp" ] || { echo "No scan data"; exit 1; }
  python3 -c "
import json, sys, datetime
entries = json.load(open(sys.argv[1]))
out = {
    'generated_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'lms_host': '$LMS_HOST',
    'models': entries
}
print(json.dumps(out, indent=2))
" "$tmp" > "$OUT_JSON"
  rm -f "$tmp"
  echo -e "  ${GREEN}Written: $OUT_JSON${RESET}"
}

# ---------------------------------------------------------------------------
# Quick API test against LM Studio local server
# ---------------------------------------------------------------------------
cmd_test() {
  echo
  echo -e "${BOLD}LM Studio API Test${RESET}  ${DIM}$LMS_HOST${RESET}"
  echo

  echo -e "  ${CYAN}GET $LMS_HOST/v1/models${RESET}"
  local models_json
  models_json=$(curl -sf --max-time 5 "$LMS_HOST/v1/models" \
    -H "Content-Type: application/json" 2>/dev/null || echo "{}")

  local model_count
  model_count=$(echo "$models_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); m=d.get('data',[]); [print(f\"    {x['id']}\") for x in m]; print(len(m))" \
    2>/dev/null | tail -1 || echo "0")

  if [ "$model_count" = "0" ] || [ -z "$model_count" ]; then
    echo -e "  ${YELLOW}Could not reach $LMS_HOST or no models listed.${RESET}"
    echo
    # Detect if this is a LAN IP that likely needs binding change
    if [[ "$LMS_HOST" =~ 192\.168\.|10\.|172\. ]]; then
      echo -e "  ${YELLOW}Remote IP detected. LM Studio binds to localhost by default.${RESET}"
      echo -e "  ${DIM}  Fix: LM Studio → Developer → Server → Network: change to 0.0.0.0${RESET}"
      echo -e "  ${DIM}  Or use LM Link for encrypted remote access (no binding change needed).${RESET}"
    else
      echo -e "  ${DIM}  In LM Studio: Developer tab → Start Server${RESET}"
    fi
    echo
    return
  fi

  echo
  local model_id
  model_id=$(echo "$models_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); m=d.get('data',[]); print(m[0]['id'] if m else '')" \
    2>/dev/null || echo "")

  [ -z "$model_id" ] && { echo -e "  ${YELLOW}No models loaded.${RESET}"; return; }

  echo -e "  ${CYAN}POST /v1/chat/completions${RESET}  model=$model_id"
  local response
  response=$(curl -sf --max-time 30 "$LMS_HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'model': '$model_id',
    'messages': [{'role': 'user', 'content': 'Reply with exactly: Hello from LM Studio'}],
    'max_tokens': 30,
    'temperature': 0
}))
")" 2>/dev/null || echo "{}")

  local reply
  reply=$(echo "$response" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" \
    2>/dev/null || echo "(no response)")

  echo -e "  ${GREEN}Reply: $reply${RESET}"
  echo
  echo -e "  ${DIM}To use from Python/any OpenAI client:${RESET}"
  echo -e "  ${DIM}  base_url = '$LMS_HOST/v1'${RESET}"
  echo -e "  ${DIM}  api_key  = 'lm-studio'  # any non-empty string${RESET}"
  echo -e "  ${DIM}  model    = '$model_id'${RESET}"
  echo
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-list}" in
  list|'')  cmd_list ;;
  --json)   cmd_json ;;
  --test)   cmd_test ;;
  --host)   LMS_HOST="$2"; shift 2; cmd_test ;;
  *) echo "Usage: $0 [list|--json|--test|--host <url>]"; exit 1 ;;
esac
