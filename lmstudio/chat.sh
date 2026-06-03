#!/usr/bin/env bash
# =============================================================================
# lmstudio/chat.sh  —  CLI chat against LM Studio local server
#
# Usage:
#   bash lmstudio/chat.sh                          # interactive model picker
#   bash lmstudio/chat.sh openai/gpt-oss-120b      # use specific model
#   bash lmstudio/chat.sh --list                   # list loaded models
#   LMS_HOST=http://192.168.1.10:1234 bash lmstudio/chat.sh
#
# Commands during chat:
#   /exit  /quit  /bye   — end session (auto-saves)
#   /new                 — clear history, start fresh
#   /model               — show current model
#   /models              — list all loaded models
#   /system <text>       — set system prompt
#   /save [file]         — save chat to JSON
#   /help                — show commands
#
# Requires: python3, curl
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

LMS_HOST="${LMS_HOST:-http://localhost:1234}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
BLUE="\033[0;34m"; MAGENTA="\033[0;35m"; RED="\033[0;31m"

# ---------------------------------------------------------------------------
# Fetch loaded models
# ---------------------------------------------------------------------------
fetch_models() {
  curl -sf --max-time 5 "$LMS_HOST/v1/models" \
    -H "Content-Type: application/json" 2>/dev/null \
  | python3 -c "
import json,sys
for m in json.load(sys.stdin).get('data',[]): print(m['id'])
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Model picker
# ---------------------------------------------------------------------------
pick_model() {
  local models
  mapfile -t models < <(fetch_models)
  if [ ${#models[@]} -eq 0 ]; then
    echo -e "${RED}No models loaded in LM Studio.${RESET}" >&2
    echo -e "${DIM}LM Studio → load a model → Developer → Start Server${RESET}" >&2
    exit 1
  fi
  if [ ${#models[@]} -eq 1 ]; then
    echo "${models[0]}"; return
  fi
  echo -e "\n${BOLD}Available models:${RESET}" >&2
  local i=1
  for m in "${models[@]}"; do
    printf "  ${CYAN}%2d)${RESET} %s\n" "$i" "$m" >&2
    i=$((i+1))
  done
  echo >&2
  while true; do
    printf "Pick a model [1-%d, default=1]: " "${#models[@]}" >&2
    read -r choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
      echo "${models[$((choice-1))]}"; return
    fi
    echo -e "  ${YELLOW}Enter a number 1–${#models[@]}${RESET}" >&2
  done
}

# ---------------------------------------------------------------------------
# Stream one turn — tokens print directly to terminal, reply saved to tmpfile
# ---------------------------------------------------------------------------
REPLY_FILE="${TMPDIR:-/tmp}/lms-reply-$$.txt"

chat_turn() {
  local model="$1" messages_json="$2" system_prompt="$3"
  : > "$REPLY_FILE"

  local full_messages
  full_messages=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
sp=sys.argv[2]
if sp: msgs=[{'role':'system','content':sp}]+msgs
print(json.dumps(msgs))
" "$messages_json" "$system_prompt")

  local payload
  payload=$(python3 -c "
import json,sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': json.loads(sys.argv[2]),
    'stream': True,
    'temperature': 0.7,
    'max_tokens': 4096
}))
" "$model" "$full_messages")

  # Use python3 for the entire SSE loop — prints tokens immediately to tty,
  # also writes full reply to REPLY_FILE so bash can read it back.
  python3 - "$payload" "$REPLY_FILE" <<'PYEOF'
import sys, json, subprocess, os

payload   = sys.argv[1]
reply_file= sys.argv[2]
lms_host  = os.environ.get("LMS_HOST","http://localhost:1234")

cmd = [
    "curl", "-sN", "--max-time", "180",
    f"{lms_host}/v1/chat/completions",
    "-H", "Content-Type: application/json",
    "-d", payload
]

full = []
try:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for raw in proc.stdout:
        line = raw.decode("utf-8", errors="replace").rstrip()
        if not line.startswith("data:"): continue
        data = line[5:].strip()
        if data == "[DONE]": break
        try:
            token = json.loads(data)["choices"][0]["delta"].get("content","")
            if token:
                sys.stdout.write(token)
                sys.stdout.flush()
                full.append(token)
        except Exception:
            pass
    proc.wait()
except Exception as e:
    sys.stdout.write(f"\n[error: {e}]")

sys.stdout.write("\n")
sys.stdout.flush()
with open(reply_file, "w") as f:
    f.write("".join(full))
PYEOF
}

# ---------------------------------------------------------------------------
# Save chat
# ---------------------------------------------------------------------------
save_chat() {
  local model="$1" messages_json="$2" file="$3"
  [ -z "$file" ] && file="$LOG_DIR/chat-$(date +%Y%m%d-%H%M%S).json"
  python3 -c "
import json,sys,datetime
print(json.dumps({
    'saved_at': datetime.datetime.now().isoformat(),
    'model': sys.argv[1],
    'lms_host': '$LMS_HOST',
    'messages': json.loads(sys.argv[2])
},indent=2))
" "$model" "$messages_json" > "$file"
  echo -e "  ${GREEN}Saved: $file${RESET}"
}

cleanup() { rm -f "$REPLY_FILE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  echo -e "\n${BOLD}Loaded models at $LMS_HOST:${RESET}"
  fetch_models | while read -r m; do echo "  $m"; done
  echo; exit 0
fi

# ---------------------------------------------------------------------------
# Pick model
# ---------------------------------------------------------------------------
if [ -n "${1:-}" ] && [[ "${1:-}" != --* ]]; then
  MODEL="$1"
else
  MODEL=$(pick_model)
fi

SYSTEM_PROMPT=""
MESSAGES="[]"
SESSION_START=$(date +%Y%m%d-%H%M%S)

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  LM Studio CLI Chat                              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo -e "  Model : ${CYAN}$MODEL${RESET}"
echo -e "  Host  : ${DIM}$LMS_HOST${RESET}"
echo -e "  Logs  : ${DIM}$LOG_DIR${RESET}"
echo -e "  ${DIM}/help für Befehle  •  /exit zum Beenden${RESET}"
echo

# ---------------------------------------------------------------------------
# Chat loop
# ---------------------------------------------------------------------------
while true; do
  printf "${BOLD}${BLUE}you${RESET} ${DIM}>>${RESET} "
  IFS= read -r user_input || break
  [ -z "$user_input" ] && continue

  case "$user_input" in
    /exit|/quit|/bye)
      echo -e "\n${DIM}Session ended. Auf Wiedersehen!${RESET}"
      save_chat "$MODEL" "$MESSAGES" "$LOG_DIR/chat-$SESSION_START.json" 2>/dev/null || true
      break ;;
    /new)
      MESSAGES="[]"
      echo -e "  ${YELLOW}History cleared.${RESET}\n"
      continue ;;
    /model)
      echo -e "  ${CYAN}$MODEL${RESET}\n"; continue ;;
    /models)
      echo
      fetch_models | while read -r m; do
        [ "$m" = "$MODEL" ] \
          && echo -e "  ${GREEN}▶ $m  (active)${RESET}" \
          || echo "    $m"
      done
      echo; continue ;;
    /system*)
      SYSTEM_PROMPT="${user_input#/system }"
      echo -e "  ${YELLOW}System prompt set: ${DIM}$SYSTEM_PROMPT${RESET}\n"
      continue ;;
    /save*)
      sf="${user_input#/save}"; sf="${sf## }"
      save_chat "$MODEL" "$MESSAGES" "${sf:-}"
      echo; continue ;;
    /help)
      echo -e "
  ${BOLD}Befehle:${RESET}
    ${CYAN}/exit /quit /bye${RESET}     — beenden (speichert automatisch)
    ${CYAN}/new${RESET}                 — History löschen
    ${CYAN}/model${RESET}               — aktives Modell anzeigen
    ${CYAN}/models${RESET}              — alle geladenen Modelle
    ${CYAN}/system <text>${RESET}       — System-Prompt setzen
    ${CYAN}/save [datei]${RESET}        — Chat als JSON speichern
    ${CYAN}/help${RESET}                — diese Hilfe
"
      continue ;;
  esac

  # Append user turn
  MESSAGES=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
msgs.append({'role':'user','content':sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$user_input")

  # Print assistant label, then stream
  short_model=$(echo "$MODEL" | sed 's|.*/||')
  printf "${BOLD}${MAGENTA}%s${RESET} ${DIM}>>${RESET} " "$short_model"

  LMS_HOST="$LMS_HOST" chat_turn "$MODEL" "$MESSAGES" "$SYSTEM_PROMPT"

  # Read reply from tmpfile, append to history
  REPLY=$(<"$REPLY_FILE")
  if [ -n "$REPLY" ]; then
    MESSAGES=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
msgs.append({'role':'assistant','content':sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$REPLY")
  fi
  echo
done
