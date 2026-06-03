#!/usr/bin/env python3
# =============================================================================
# lmstudio/chat_with_tools.py
# CLI chat mit tool-calling: fetch_url + web_search
#
# Usage:
#   python lmstudio/chat_with_tools.py
#   python lmstudio/chat_with_tools.py --model qwen2.5
#   python lmstudio/chat_with_tools.py --no-color
#   python lmstudio/chat_with_tools.py --debug
#   PERPLEXITY_API_KEY=pplx-xxx python lmstudio/chat_with_tools.py
#
# Python 3.8+ kompatibel
# License: AGPL-3.0-or-later OR MIT - Copyright 2026 GrEEV.com KG
# =============================================================================
from __future__ import annotations
import os, sys, json, argparse, datetime, urllib.request, urllib.error
from pathlib import Path

# UTF-8 stdout erzwingen (wichtig fuer Windows cp1252 / Python 3.8-32bit)
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

# ----------------------------------------------------------------
# ANSI-Farben auto-detect
# Deaktiviert wenn:
#   - NO_COLOR env gesetzt (https://no-color.org)
#   - --no-color Flag
#   - stdout ist kein TTY (Pipe/Redirect)
#   - Windows + powershell.exe 5.1 (kein ANSI-Support)
# ----------------------------------------------------------------
def _detect_color() -> bool:
    if os.environ.get('NO_COLOR'):
        return False
    if not sys.stdout.isatty():
        return False
    # Windows: powershell.exe (5.1) kann kein ANSI, pwsh (7+) schon
    if sys.platform == 'win32':
        # ANSI aktivieren via Windows Console API
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            mode   = ctypes.c_ulong()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                if mode.value & 0x0004:  # schon aktiv (Windows Terminal / pwsh)
                    return True
                # versuchen zu aktivieren
                if kernel32.SetConsoleMode(handle, mode.value | 0x0004):
                    return True
            return False
        except Exception:
            return False
    return True

COLOR = _detect_color()

if COLOR:
    R      = "\033[0m"
    BOLD   = "\033[1m"
    DIM    = "\033[2m"
    CYAN   = "\033[0;36m"
    GREEN  = "\033[0;32m"
    YELLOW = "\033[1;33m"
    BLUE   = "\033[0;34m"
    MAGENTA= "\033[0;35m"
    RED    = "\033[0;31m"
else:
    R = BOLD = DIM = CYAN = GREEN = YELLOW = BLUE = MAGENTA = RED = ""

SCRIPT_DIR = Path(__file__).parent
LOG_DIR    = SCRIPT_DIR.parent / "logs"
LOG_DIR.mkdir(exist_ok=True)

LMS_HOST     = os.environ.get("LMS_HOST", "http://localhost:1234")
DEBUG        = False
TIMEOUT_LLM  = int(os.environ.get("LMS_TIMEOUT",      "300"))
TIMEOUT_FETCH= int(os.environ.get("LMS_FETCH_TIMEOUT", "20"))
TIMEOUT_API  = 10

sys.path.insert(0, str(SCRIPT_DIR))
from tools import fetch_url, web_search

TOOLS    = [fetch_url.DEFINITION, web_search.DEFINITION]
TOOL_MAP = {"fetch_url": fetch_url.run, "web_search": web_search.run}


def get(path: str) -> dict:
    req = urllib.request.Request(
        f"{LMS_HOST}{path}",
        headers={"Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_API) as r:
        return json.load(r)


def post(path: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        f"{LMS_HOST}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_LLM) as r:
        return json.load(r)


def list_models() -> list:
    try:
        d = get("/v1/models")
        return [m["id"] for m in d.get("data", [])]
    except Exception as e:
        if DEBUG:
            print(f"{RED}list_models: {e}{R}", file=sys.stderr)
        return []


def pick_model(preferred):
    models = list_models()
    if not models:
        print(f"{RED}Keine Modelle gefunden - Server erreichbar?{R}")
        print(f"  curl -s {LMS_HOST}/v1/models")
        sys.exit(1)
    if preferred:
        for m in models:
            if preferred.lower() in m.lower():
                return m
        print(f"{YELLOW}Modell '{preferred}' nicht gefunden:{R}")
        for m in models:
            print(f"  {m}")
        sys.exit(1)
    if len(models) == 1:
        return models[0]
    print(f"\n{BOLD}Verfuegbare Modelle:{R}")
    for i, m in enumerate(models, 1):
        print(f"  {CYAN}{i:2}){R} {m}")
    while True:
        choice = input(f"\nWahl [1-{len(models)}, default=1]: ").strip() or "1"
        if choice.isdigit() and 1 <= int(choice) <= len(models):
            return models[int(choice) - 1]


def chat(model: str, messages: list, system: str = ""):
    all_messages = ([{"role": "system", "content": system}] if system else []) + messages

    while True:
        resp   = post("/v1/chat/completions", {
            "model":       model,
            "messages":    all_messages,
            "tools":       TOOLS,
            "tool_choice": "auto",
            "temperature": 0.7,
            "max_tokens":  2048,
            "stream":      False,
        })
        choice = resp["choices"][0]
        msg    = choice["message"]
        finish = choice.get("finish_reason", "stop")
        all_messages.append(msg)

        if finish == "tool_calls" or msg.get("tool_calls"):
            for tc in msg.get("tool_calls", []):
                fn   = tc["function"]["name"]
                args = json.loads(tc["function"]["arguments"])
                args_str = ", ".join(f"{k}={repr(v)}" for k, v in args.items())
                print(f"\n  {YELLOW}* {fn}{R}({args_str})")
                result = TOOL_MAP[fn](**args) if fn in TOOL_MAP else {"error": f"Unknown tool: {fn}"}
                if result.get("error"):
                    print(f"  {RED}  ERR {result['error']}{R}")
                else:
                    preview = str(result)[:120].replace("\n", " ")
                    print(f"  {GREEN}  OK  {preview}...{R}")
                all_messages.append({
                    "role":        "tool",
                    "tool_call_id": tc["id"],
                    "content":     json.dumps(result, ensure_ascii=False),
                })
            continue

        return msg.get("content") or "", all_messages


def save(model: str, messages: list, path: Path):
    path.write_text(json.dumps({
        "saved_at": datetime.datetime.now().isoformat(),
        "model":    model,
        "lms_host": LMS_HOST,
        "tools":    [t["function"]["name"] for t in TOOLS],
        "messages": messages,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  {GREEN}Saved: {path}{R}")


def main():
    global DEBUG, COLOR
    ap = argparse.ArgumentParser(description="LM Studio CLI Chat mit Tools")
    ap.add_argument("--model",    "-m", default=None,  help="Modellname oder Fragment")
    ap.add_argument("--system",   "-s", default="",    help="System-Prompt")
    ap.add_argument("--list",     "-l", action="store_true", help="Modelle auflisten")
    ap.add_argument("--debug",    "-d", action="store_true", help="Debug-Ausgabe")
    ap.add_argument("--no-color",       action="store_true", help="ANSI-Farben deaktivieren")
    args = ap.parse_args()

    DEBUG = args.debug
    if args.no_color:
        # alle Farbvariablen leeren
        global R, BOLD, DIM, CYAN, GREEN, YELLOW, BLUE, MAGENTA, RED
        R = BOLD = DIM = CYAN = GREEN = YELLOW = BLUE = MAGENTA = RED = ""
        COLOR = False

    if args.list:
        models = list_models()
        if not models:
            print(f"Server nicht erreichbar: {LMS_HOST}")
        for m in models:
            print(m)
        return

    model         = pick_model(args.model)
    system        = args.system
    messages      = []
    session       = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    search_hint   = "Perplexity" if os.environ.get("PERPLEXITY_API_KEY") else "DuckDuckGo"
    color_hint    = "Farbe" if COLOR else "Plain"

    print()
    print("+================================================+")
    print("|  LM Studio CLI Chat  +Tools                    |")
    print("+================================================+")
    print(f"  Modell  : {CYAN}{model}{R}")
    print(f"  Tools   : {GREEN}fetch_url  web_search ({search_hint}){R}")
    print(f"  Host    : {DIM}{LMS_HOST}{R}")
    print(f"  Timeout : {DIM}{TIMEOUT_LLM}s  |  Output: {color_hint}{R}")
    print(f"  {DIM}Einfach chatten - Modell ruft Tools selbst auf{R}")
    print(f"  {DIM}/help  /exit  /new  /system  /save{R}")
    print()

    while True:
        try:
            user_input = input(f"{BOLD}{BLUE}you{R} >> ").strip()
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
            print(f"  {YELLOW}System prompt gesetzt.{R}\n")
            continue
        elif user_input.startswith("/save"):
            sf = user_input[5:].strip()
            save(model, messages, Path(sf) if sf else LOG_DIR / f"chat-tools-{session}.json")
            print()
            continue
        elif user_input == "/help":
            print(f"""
  Befehle:
    {CYAN}/exit /quit /bye{R}     beenden (speichert)
    {CYAN}/new{R}                 History loeschen
    {CYAN}/system <text>{R}       System-Prompt setzen
    {CYAN}/save [datei]{R}        Chat speichern

  Tools (automatisch):
    {GREEN}fetch_url(url){R}      Webseite lesen
    {GREEN}web_search(query){R}   Suchen ({search_hint})

  Timeout erhoehen:
    $env:LMS_TIMEOUT=600   (PowerShell)

  Perplexity aktivieren:
    $env:PERPLEXITY_API_KEY='pplx-xxx'

  Farben deaktivieren:
    $env:NO_COLOR=1        (Standard: https://no-color.org)
""")
            continue

        messages.append({"role": "user", "content": user_input})
        short = model.split("/")[-1]
        print(f"{BOLD}{MAGENTA}{short}{R} >> ", end="", flush=True)

        try:
            reply, updated = chat(model, messages, system)
            messages = [m for m in updated
                        if not (isinstance(m, dict) and m.get("role") == "system")]
            print(f"{GREEN}{reply}{R}")
        except Exception as e:
            print(f"\n{RED}Fehler: {e}{R}")
            if "timed out" in str(e):
                print(f"  Tipp: $env:LMS_TIMEOUT=600 dann neu starten")
            if DEBUG:
                import traceback
                traceback.print_exc()
            if messages and messages[-1].get("role") == "user":
                messages.pop()

        print()


if __name__ == "__main__":
    main()
