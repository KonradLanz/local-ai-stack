#!/usr/bin/env python3
# =============================================================================
# lmstudio/chat_with_tools.py
# CLI chat with tool-calling: fetch_url + web_search
#
# Usage:
#   python3 lmstudio/chat_with_tools.py
#   python3 lmstudio/chat_with_tools.py --model openai/gpt-oss-120b
#   python3 lmstudio/chat_with_tools.py --model yoyo-v2-claude-4.6-mlx-gs32
#   PERPLEXITY_API_KEY=pplx-xxx python3 lmstudio/chat_with_tools.py
#
# The model decides on its own when to call fetch_url or web_search.
# You just chat normally — mention a URL or ask about current events.
#
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
import os, sys, json, argparse, datetime, urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
LOG_DIR = SCRIPT_DIR.parent / "logs"
LOG_DIR.mkdir(exist_ok=True)

LMS_HOST = os.environ.get("LMS_HOST", "http://localhost:1234")

# --- colors ---
R="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
BLUE="\033[0;34m"; MAGENTA="\033[0;35m"; RED="\033[0;31m"

# --- load tools ---
sys.path.insert(0, str(SCRIPT_DIR))
from tools import fetch_url, web_search

TOOLS = [fetch_url.DEFINITION, web_search.DEFINITION]
TOOL_MAP = {
    "fetch_url": fetch_url.run,
    "web_search": web_search.run,
}


def api(path: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{LMS_HOST}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def list_models() -> list[str]:
    try:
        d = api("/v1/models", {})
        return [m["id"] for m in d.get("data", [])]
    except Exception:
        return []


def pick_model(preferred: str | None) -> str:
    models = list_models()
    if not models:
        print(f"{RED}No models loaded in LM Studio.{R}")
        sys.exit(1)
    if preferred:
        # fuzzy match
        for m in models:
            if preferred.lower() in m.lower():
                return m
        print(f"{YELLOW}Model '{preferred}' not found, available:{R}")
        for m in models: print(f"  {m}")
        sys.exit(1)
    if len(models) == 1:
        return models[0]
    print(f"\n{BOLD}Available models:{R}")
    for i, m in enumerate(models, 1):
        print(f"  {CYAN}{i:2}){R} {m}")
    while True:
        choice = input(f"\nPick [1-{len(models)}, default=1]: ").strip() or "1"
        if choice.isdigit() and 1 <= int(choice) <= len(models):
            return models[int(choice)-1]


def chat(model: str, messages: list, system: str = "") -> tuple[str, list]:
    """
    One full round-trip including automatic tool calls.
    Returns (assistant_text, updated_messages).
    Supports multi-step tool use (model can call tools multiple times).
    """
    all_messages = ([{"role": "system", "content": system}] if system else []) + messages

    while True:
        resp = api("/v1/chat/completions", {
            "model": model,
            "messages": all_messages,
            "tools": TOOLS,
            "tool_choice": "auto",
            "temperature": 0.7,
            "max_tokens": 4096,
            "stream": False,   # tool-calling needs non-streaming for tool_calls field
        })

        choice = resp["choices"][0]
        msg = choice["message"]
        finish = choice.get("finish_reason", "stop")

        all_messages.append(msg)

        if finish == "tool_calls" or msg.get("tool_calls"):
            for tc in msg.get("tool_calls", []):
                fn   = tc["function"]["name"]
                args = json.loads(tc["function"]["arguments"])
                print(f"\n  {YELLOW}⚙ {fn}{R}({', '.join(f'{k}={repr(v)}' for k,v in args.items())})")

                if fn in TOOL_MAP:
                    result = TOOL_MAP[fn](**args)
                else:
                    result = {"error": f"Unknown tool: {fn}"}

                if result.get("error"):
                    print(f"  {RED}  ✗ {result['error']}{R}")
                else:
                    preview = str(result)[:120].replace('\n',' ')
                    print(f"  {GREEN}  ✓ {preview}…{R}")

                all_messages.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": json.dumps(result, ensure_ascii=False)
                })
            # loop — model will now process tool results
            continue

        # Final text response
        text = msg.get("content") or ""
        return text, all_messages


def save(model: str, messages: list, path: Path):
    path.write_text(json.dumps({
        "saved_at": datetime.datetime.now().isoformat(),
        "model": model,
        "lms_host": LMS_HOST,
        "tools_enabled": [t["function"]["name"] for t in TOOLS],
        "messages": messages
    }, ensure_ascii=False, indent=2))
    print(f"  {GREEN}Saved: {path}{R}")


def main():
    ap = argparse.ArgumentParser(description="LM Studio CLI chat with tools")
    ap.add_argument("--model", "-m", default=None, help="Model name or fragment")
    ap.add_argument("--system", "-s", default="", help="System prompt")
    ap.add_argument("--list",   "-l", action="store_true", help="List models and exit")
    args = ap.parse_args()

    if args.list:
        for m in list_models(): print(m)
        return

    model = pick_model(args.model)
    system = args.system
    messages: list = []
    session = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

    search_hint = "Perplexity" if os.environ.get("PERPLEXITY_API_KEY") else "DuckDuckGo"

    print()
    print(f"{BOLD}╔══════════════════════════════════════════════════╗{R}")
    print(f"{BOLD}║  LM Studio CLI Chat  +Tools                      ║{R}")
    print(f"{BOLD}╚══════════════════════════════════════════════════╝{R}")
    print(f"  Model  : {CYAN}{model}{R}")
    print(f"  Tools  : {GREEN}fetch_url  web_search ({search_hint}){R}")
    print(f"  Host   : {DIM}{LMS_HOST}{R}")
    print(f"  {DIM}Einfach chatten — das Modell ruft Tools selbst auf{R}")
    print(f"  {DIM}/exit /new /system /save /help{R}")
    print()

    while True:
        try:
            user_input = input(f"{BOLD}{BLUE}you{R} {DIM}>>{R} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            user_input = "/exit"

        if not user_input:
            continue

        # commands
        if user_input in ("/exit", "/quit", "/bye"):
            print(f"\n{DIM}Auf Wiedersehen!{R}")
            if messages:
                save(model, messages, LOG_DIR / f"chat-tools-{session}.json")
            break
        if user_input == "/new":
            messages = []
            print(f"  {YELLOW}History cleared.{R}\n")
            continue
        if user_input.startswith("/system "):
            system = user_input[8:]
            print(f"  {YELLOW}System prompt: {DIM}{system}{R}\n")
            continue
        if user_input.startswith("/save"):
            sf = user_input[5:].strip()
            p = Path(sf) if sf else LOG_DIR / f"chat-tools-{session}.json"
            save(model, messages, p)
            print()
            continue
        if user_input == "/help":
            print(f"""
  {BOLD}Befehle:{R}
    {CYAN}/exit /quit /bye{R}     — beenden
    {CYAN}/new{R}                 — History löschen
    {CYAN}/system <text>{R}       — System-Prompt setzen
    {CYAN}/save [datei]{R}        — Chat speichern
    {CYAN}/help{R}                — diese Hilfe

  {BOLD}Tools (automatisch vom Modell aufgerufen):{R}
    {GREEN}fetch_url(url){R}      — Webseite lesen
    {GREEN}web_search(query){R}   — Web suchen ({search_hint})

  {BOLD}Perplexity Search aktivieren:{R}
    {DIM}PERPLEXITY_API_KEY=pplx-xxx python3 lmstudio/chat_with_tools.py{R}
""")
            continue

        # chat turn
        messages.append({"role": "user", "content": user_input})
        short = model.split("/")[-1]
        print(f"{BOLD}{MAGENTA}{short}{R} {DIM}>>{R} ", end="", flush=True)

        try:
            reply, updated = chat(model, messages[:-1] + [{"role":"user","content":user_input}], system)
            # rebuild messages from updated (includes tool call messages)
            messages = [m for m in updated if not (isinstance(m,dict) and m.get("role")=="system")]
            print(f"{GREEN}{reply}{R}")
        except Exception as e:
            print(f"\n{RED}Error: {e}{R}")
            messages.pop()  # remove failed user message

        print()


if __name__ == "__main__":
    main()
