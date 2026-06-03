#!/usr/bin/env bash
# =============================================================================
# lmstudio/discover-models.sh
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_JSON="$SCRIPT_DIR/models.json"
LMS_HOST="${LMS_HOST:-http://localhost:1234}"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"
DIM="\033[2m"; BOLD="\033[1m"; RESET="\033[0m"

candidate_dirs() {
  echo "$HOME/.lmstudio/models"
  echo "$HOME/Library/Application Support/LM-Studio/models"
  echo "$HOME/Library/Caches/lm-studio/models"
  echo "$HOME/.cache/lm-studio/models"
  echo "$HOME/.local/share/lm-studio/models"
  local cfg="$HOME/.lmstudio/config.json"
  if [ -f "$cfg" ] && command -v python3 &>/dev/null; then
    python3 -c "
import json
try:
    d=json.load(open('$cfg'))
    p=d.get('modelsDir') or d.get('models_dir') or d.get('modelDirectory')
    if p: print(p)
except: pass
" 2>/dev/null || true
  fi
}

scan_models() {
  local found=()
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
      found+=("$f")
    done < <(find "$dir" -maxdepth 4 -type f \( \
      -name "*.gguf" -o -name "*.safetensors" -o \
      -name "*.bin"  -o -name "*.ggml" \) \
      -not -path "*/blobs/*" -print0 2>/dev/null)
  done < <(candidate_dirs)
  local seen=()
  for f in "${found[@]:-}"; do
    [[ " ${seen[*]:-} " == *" $f "* ]] && continue
    seen+=("$f"); echo "$f"
  done
}

# Use python3 for float formatting — avoids locale decimal separator issues (de_AT uses comma)
fmt_size() {
  python3 -c "
import sys
b=int(sys.argv[1])
if   b>=1073741824: print(f'{b/1073741824:.1f} GB')
elif b>=1048576:    print(f'{b/1048576:.0f} MB')
else:               print(f'{b//1024} KB')
" "$1"
}

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
import json,sys
e=json.loads(sys.argv[1])
e.append({'name':sys.argv[2],'file':sys.argv[3],'path':sys.argv[4],'size_bytes':int(sys.argv[5])})
print(json.dumps(e))
" "$json_entries" "$model_name" "$filename" "$filepath" "$size" 2>/dev/null || echo "$json_entries")
  done < <(scan_models)

  echo
  if [ "$count" -eq 0 ]; then
    echo -e "  ${YELLOW}No models found.${RESET}"
    echo -e "  ${DIM}Open LM Studio and download a model first.${RESET}"
  else
    echo -e "  ${GREEN}$count model(s) found${RESET}  ($(fmt_size "$total_bytes") total)"
  fi
  echo
  echo "$json_entries" > "${TMPDIR:-/tmp}/lms-models-$$.json"
}

cmd_json() {
  cmd_list
  local tmp="${TMPDIR:-/tmp}/lms-models-$$.json"
  [ -f "$tmp" ] || { echo "No scan data"; exit 1; }
  python3 -c "
import json,sys,datetime
e=json.load(open(sys.argv[1]))
print(json.dumps({'generated_at':datetime.datetime.utcnow().isoformat()+'Z','lms_host':'$LMS_HOST','models':e},indent=2))
" "$tmp" > "$OUT_JSON"
  rm -f "$tmp"
  echo -e "  ${GREEN}Written: $OUT_JSON${RESET}"
}

cmd_test() {
  echo
  echo -e "${BOLD}LM Studio API Test${RESET}  ${DIM}$LMS_HOST${RESET}"
  echo
  echo -e "  ${CYAN}GET $LMS_HOST/v1/models${RESET}"
  local models_json
  models_json=$(curl -sf --max-time 5 "$LMS_HOST/v1/models" \
    -H "Content-Type: application/json" 2>/dev/null || echo "{}")

  echo "$models_json" | python3 -c \
    "import json,sys; [print(f\"    {m['id']}\") for m in json.load(sys.stdin).get('data',[])]" \
    2>/dev/null || true
  echo

  local model_id
  model_id=$(echo "$models_json" | python3 -c \
    "import json,sys; m=json.load(sys.stdin).get('data',[]); print(m[0]['id'] if m else '')" \
    2>/dev/null || echo "")

  if [ -z "$model_id" ]; then
    echo -e "  ${YELLOW}Could not reach $LMS_HOST or no models listed.${RESET}"
    if [[ "$LMS_HOST" =~ 192\.168\.|10\.|172\. ]]; then
      echo -e "  ${DIM}  Fix: LM Studio → Developer → Server → Network → 0.0.0.0${RESET}"
      echo -e "  ${DIM}  Or use LM Link for encrypted remote access.${RESET}"
    else
      echo -e "  ${DIM}  LM Studio → Developer tab → Start Server${RESET}"
    fi
    echo; return
  fi

  echo -e "  ${CYAN}POST /v1/chat/completions${RESET}  model=$model_id"
  local reply
  reply=$(curl -sf --max-time 30 "$LMS_HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'model':'$model_id','messages':[{'role':'user','content':'Reply with exactly: Hello from LM Studio'}],'max_tokens':30,'temperature':0}))" )" \
    2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" \
    2>/dev/null || echo "(no response)")

  echo -e "  ${GREEN}Reply: $reply${RESET}"
  echo
  echo -e "  ${DIM}base_url = '$LMS_HOST/v1'   api_key = 'lm-studio'   model = '$model_id'${RESET}"
  echo
}

case "${1:-list}" in
  list|'')  cmd_list ;;
  --json)   cmd_json ;;
  --test)   cmd_test ;;
  --host)   LMS_HOST="$2"; shift 2; cmd_test ;;
  *)        echo "Usage: $0 [list|--json|--test|--host <url>]"; exit 1 ;;
esac
