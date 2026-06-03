#!/usr/bin/env python3
# =============================================================================
# lmstudio/chat_with_tools.py
# CLI chat mit tool-calling: fetch_url + web_search
#
# Usage:
#   python3 lmstudio/chat_with_tools.py
#   python3 lmstudio/chat_with_tools.py --model yoyo
#   python3 lmstudio/chat_with_tools.py --debug
#   PERPLEXITY_API_KEY=pplx-xxx python3 lmstudio/chat_with_tools.py
#
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
import os, sys, json, argparse, datetime, urllib.request, urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
LOG_DIR = SCRIPT_DIR.parent / "logs"
LOG_DIR.mkdir(exist_ok=True)

LMS_HOST = os.environ.get("LMS_HOST", "http://localhost:1234")
DEBUG = False

R="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"
BLUE="\033[0;34m"; MAGENTA="\033[0;35m"; RED="\033[0;31m"

sys.path.insert(0, str(SCRIPT_DIR))
from tools import fetch_url, web_search

TOOLS = [fetch_url.DEFINITION, web_search.DEFINITION]
TOOL_MAP = {"fetch_url": fetch_url.run, "web_search": web_search.run}


def get(path: str) -> dict:
    """HTTP GET."""
    req = urllib.request.Request(
        f"{LMS_HOST}{path}",
        headers={"Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except Exception as e:
        if DEBUG:
            print(f"{RED}GET {path} => {e}{R}", file=sys.stderr)
        raise


def post(path: str, payload: dict) -> dict:
    """HTTP POST."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{LMS_HOST}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except Exception as e:
        if DEBUG:
            print(f"{RED}POST {path} => {e}{R}", file=sys.stderr)
        raise


def list_models() -> list[str]:
    try:
        d = get("/v1/models")   # GET, nicht POST!
        return [m["id"] for m in d.get("data", [])]
    except Exception as e:
        if DEBUG:
            print(f"{RED}list_models: {e}{R}", file=sys.stderr)
        return []


def pick_model(preferred: str | None) -> str:
    models = list_models()
    if not models:
        print(f"{RED}Keine Modelle gefunden — Server erreichbar?{R}")
        print(f"  {DIM}curl -s {LMS_HOST}/v1/models{R}")
        print(f"  {DIM}--debug fuer Details{R}")
        sys.exit(1)
    if preferred:
        for m in models:
            if preferred.lower() in m.lower():
                return m
        print(f"{YELLOW}Modell '{preferred}' nicht gefunden:{R}")
        for m in models: print(f"  {m}")
        sys.exit(1)
    if len(models) == 1:
        return models[0]
    print(f"\n{BOLD}Verfuegbare Modelle:{R}")
    for i, m in enumerate(models, 1):
        print(f"  {CYAN}{i:2}){R} {m}")
    while True:
        choice = input(f"\nWahl [1-{len(models)}, default=1]: ").strip() or "1"
        if choice.isdigit() and 1 <= int(choice) <= len(models):
            return models[int(choice)-1]


def chat(model: str, messages: list, system: str = "") -> tuple[str, list]:
    all_messages = ([{"role": "system", "content": system}] if system else []) + messages

    while True:
        resp = post("/v1/chat/completions", {
            "model": model,
            "messages": all_messages,
            "tools": TOOLS,
            "tool_choice": "auto",
            "temperature": 0.7,
            "max_tokens": 4096,
            "stream": False,
        })

        choice  = resp["choices"][0]
        msg     = choice["message"]
        finish  = choice.get("finish_reason", "stop")
        all_messages.append(msg)

        if finish == "tool_calls" or msg.get("tool_calls"):
            for tc in msg.get("tool_calls", []):
                fn   = tc["function"]["name"]
                args = json.loads(tc["function"]["arguments"])
                print(f"\n  {YELLOW}⚙ {fn}{R}({', '.join(f'{k}={repr(v)}' for k,v in args.items())})")
                result = TOOL_MAP[fn](**args) if fn in TOOL_MAP else {"error": f"Unknown tool: {fn}"}
                if result.get("error"):
                    print(f"  {RED}  ✗ {result['error']}{R}")
                else:
                    print(f"  {GREEN}  ✓ {str(result)[:120].replace(chr(10),' ')}…{R}")
                all_messages.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": json.dumps(result, ensure_ascii=False)
                })
            continue

        return msg.get("content") or "", all_messages


def save(model: str, messages: list, path: Path):
    path.write_text(json.dumps({
        "saved_at": datetime.datetime.now().isoformat(),
        "model": model,
        "lms_host": LMS_HOST,
        "tools": [t["function"]["name"] for t in TOOLS],
        "messages": messages
    }, ensure_ascii=False, indent=2))
    print(f"  {GREEN}Saved: {path}{R}")


def main():
    global DEBUG
    ap = argparse.ArgumentParser(description="LM Studio CLI Chat mit Tools")
    ap.add_argument("--model",  "-m", default=None, help="Modellname oder Fragment")
    ap.add_argument("--system", "-s", default="",   help="System-Prompt")
    ap.add_argument("--list",   "-l", action="store_true", help="Modelle auflisten")
    ap.add_argument("--debug",  "-d", action="store_true", help="Debug-Ausgabe")
    args = ap.parse_args()
    DEBUG = args.debug

    if args.list:
        models = list_models()
        if not models:
            print(f"{RED}Server nicht erreichbar: {LMS_HOST}{R}")
        for m in models: print(m)
        return

    model   = pick_model(args.model)
    system  = args.system
    messages: list = []
    session = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    search_hint = "Perplexity" if os.environ.get("PERPLEXITY_API_KEY") else "DuckDuckGo"

    print()
    print(f"{BOLD}╔══════════════════════════════════════════════════╗{R}")
    print(f"{BOLD}║  LM Studio CLI Chat  +Tools                      ║{R}")
    print(f"{BOLD}╚══════════════════════════════════════════════════╝{R}")
    print(f"  Modell : {CYAN}{model}{R}")
    print(f"  Tools  : {GREEN}fetch_url  web_search ({search_hint}){R}")
    print(f"  Host   : {DIM}{LMS_HOST}{R}")
    print(f"  {DIM}Einfach chatten — Modell ruft Tools selbst auf{R}")
    print(f"  {DIM}/help  /exit  /new  /system  /save{R}")
    print()

    while True:
        try:
            user_input = input(f"{BOLD}{BLUE}you{R} {DIM}>>{R} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            user_input = "/exit"

        if not user_input:
            continue

        if user_input in ("/exit", "/quit", "/bye"):
            print(f"\n{DIM}Auf Wiedersehen!{R}")
            if messages:
                save(model, messages, LOG_DIR / f"chat-tools-{session}.json")
            break
        elif user_input == "/new":
            messages = []
            print(f"  {YELLOW}History geloescht.{R}\n")
            continue
        elif user_input.startswith("/system "):
            system = user_input[8:]
            print(f"  {YELLOW}System prompt: {DIM}{system}{R}\n")
            continue
        elif user_input.startswith("/save"):
            sf = user_input[5:].strip()
            save(model, messages, Path(sf) if sf else LOG_DIR / f"chat-tools-{session}.json")
            print()
            continue
        elif user_input == "/help":
            print(f"""
  {BOLD}Befehle:{R}
    {CYAN}/exit /quit /bye{R}     — beenden (speichert)
    {CYAN}/new{R}                 — History loeschen
    {CYAN}/system <text>{R}       — System-Prompt
    {CYAN}/save [datei]{R}        — Chat speichern

  {BOLD}Tools (automatisch):{R}
    {GREEN}fetch_url(url){R}      — Webseite lesen
    {GREEN}web_search(query){R}   — Suchen ({search_hint})

  {BOLD}Perplexity aktivieren:{R}
    {DIM}PERPLEXITY_API_KEY=pplx-xxx python3 lmstudio/chat_with_tools.py{R}
""")
            continue

        messages.append({"role": "user", "content": user_input})
        short = model.split("/")[-1]
        print(f"{BOLD}{MAGENTA}{short}{R} {DIM}>>{R} ", end="", flush=True)

        try:
            reply, updated = chat(model, messages, system)
            messages = [m for m in updated if not (isinstance(m, dict) and m.get("role") == "system")]
            print(f"{GREEN}{reply}{R}")
        except Exception as e:
            print(f"\n{RED}Fehler: {e}{R}")
            if DEBUG:
                import traceback; traceback.print_exc()
            messages.pop()

        print()


if __name__ == "__main__":
    main()
