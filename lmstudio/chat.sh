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
#   /exit  /quit  /bye   — end session
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
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../logs" 2>/dev/null && pwd || echo "${HOME}/.local/share/lmstudio-chats")"
mkdir -p "$LOG_DIR"

# Colors
RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
BLUE="\033[0;34m"; MAGENTA="\033[0;35m"; RED="\033[0;31m"

die() { echo -e "${RED}Error: $*${RESET}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fetch loaded models from LM Studio
# ---------------------------------------------------------------------------
fetch_models() {
  curl -sf --max-time 5 "$LMS_HOST/v1/models" \
    -H "Content-Type: application/json" 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('data',[]): print(m['id'])
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Interactive model picker
# ---------------------------------------------------------------------------
pick_model() {
  local models
  mapfile -t models < <(fetch_models)
  if [ ${#models[@]} -eq 0 ]; then
    echo -e "${RED}No models loaded in LM Studio.${RESET}"
    echo -e "${DIM}Open LM Studio → load a model → Developer → Start Server${RESET}"
    exit 1
  fi
  if [ ${#models[@]} -eq 1 ]; then
    echo "${models[0]}"
    return
  fi
  echo -e "\n${BOLD}Available models:${RESET}" >&2
  local i=1
  for m in "${models[@]}"; do
    echo -e "  ${CYAN}$i)${RESET} $m" >&2
    i=$((i+1))
  done
  echo >&2
  while true; do
    printf "Pick a model [1-%d, default=1]: " "${#models[@]}" >&2
    read -r choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
      echo "${models[$((choice-1))]}"
      return
    fi
    echo -e "  ${YELLOW}Enter a number between 1 and ${#models[@]}${RESET}" >&2
  done
}

# ---------------------------------------------------------------------------
# Stream one assistant turn, return full text
# ---------------------------------------------------------------------------
chat_turn() {
  local model="$1" messages_json="$2" system_prompt="$3"

  # Build message array with optional system prompt
  local full_messages
  full_messages=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
sys_p=sys.argv[2]
if sys_p:
    msgs=[{'role':'system','content':sys_p}]+msgs
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

  # Stream with SSE parsing — print tokens as they arrive
  local full_reply=""
  echo -e -n "${GREEN}"
  while IFS= read -r line; do
    [[ "$line" == data:* ]] || continue
    local data="${line#data: }"
    [ "$data" = "[DONE]" ] && break
    local token
    token=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
    t=d['choices'][0]['delta'].get('content','')
    sys.stdout.write(t)
except: pass
" "$data" 2>/dev/null || true)
    full_reply+="$token"
  done < <(curl -sN --max-time 120 "$LMS_HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  echo -e "${RESET}"
  echo "$full_reply"
}

# ---------------------------------------------------------------------------
# Save chat to JSON
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

# ---------------------------------------------------------------------------
# --list flag
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  echo -e "\n${BOLD}Loaded models at $LMS_HOST:${RESET}"
  fetch_models | while read -r m; do echo "  $m"; done
  echo
  exit 0
fi

# ---------------------------------------------------------------------------
# Main: pick model, start session
# ---------------------------------------------------------------------------
if [ -n "${1:-}" ] && [[ "${1:-}" != --* ]]; then
  MODEL="$1"
else
  MODEL=$(pick_model)
fi

SYSTEM_PROMPT=""
MESSAGES="[]"
SESSION_START=$(date +%Y%m%d-%H%M%S)

clear
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  LM Studio CLI Chat                              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo -e "  Model : ${CYAN}$MODEL${RESET}"
echo -e "  Host  : ${DIM}$LMS_HOST${RESET}"
echo -e "  Logs  : ${DIM}$LOG_DIR${RESET}"
echo -e "  ${DIM}Type /help for commands, /exit to quit${RESET}"
echo

while true; do
  # Prompt
  printf "${BOLD}${BLUE}you${RESET} ${DIM}>>${RESET} "
  IFS= read -r user_input || break
  [ -z "$user_input" ] && continue

  # Commands
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
      echo -e "  ${CYAN}$MODEL${RESET}\n"
      continue ;;
    /models)
      echo
      fetch_models | while read -r m; do
        [ "$m" = "$MODEL" ] && echo -e "  ${GREEN}▶ $m${RESET}" || echo "    $m"
      done
      echo; continue ;;
    /system*)
      SYSTEM_PROMPT="${user_input#/system }"
      echo -e "  ${YELLOW}System prompt set.${RESET}\n"
      continue ;;
    /save*)
      savefile="${user_input#/save}"; savefile="${savefile## }"
      save_chat "$MODEL" "$MESSAGES" "${savefile:-}"
      echo; continue ;;
    /help)
      echo -e "
  ${BOLD}Commands:${RESET}
    ${CYAN}/exit /quit /bye${RESET}   — end session (auto-saves)
    ${CYAN}/new${RESET}               — clear history
    ${CYAN}/model${RESET}             — show current model
    ${CYAN}/models${RESET}            — list all loaded models
    ${CYAN}/system <text>${RESET}     — set system prompt
    ${CYAN}/save [file]${RESET}       — save chat to JSON
    ${CYAN}/help${RESET}              — this message
"
      continue ;;
  esac

  # Append user message
  MESSAGES=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
msgs.append({'role':'user','content':sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$user_input")

  # Assistant header
  echo -e "${BOLD}${MAGENTA}$(echo "$MODEL" | sed 's|.*/||')${RESET} ${DIM}>>${RESET} "

  # Stream response
  REPLY=$(chat_turn "$MODEL" "$MESSAGES" "$SYSTEM_PROMPT")

  # Append assistant message
  MESSAGES=$(python3 -c "
import json,sys
msgs=json.loads(sys.argv[1])
msgs.append({'role':'assistant','content':sys.argv[2]})
print(json.dumps(msgs))
" "$MESSAGES" "$REPLY")

  echo
done
