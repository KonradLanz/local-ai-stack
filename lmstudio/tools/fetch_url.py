# =============================================================================
# lmstudio/tools/fetch_url.py
# Tool: fetch the readable text content of a URL (strips HTML tags)
# Used by chat_with_tools.py as an OpenAI function-calling tool.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
import urllib.request, urllib.error, re, json
from typing import Any

DEFINITION = {
    "type": "function",
    "function": {
        "name": "fetch_url",
        "description": (
            "Fetches the text content of a web page. "
            "Use this to read news articles, documentation, or any URL the user mentions. "
            "Returns the page title and first ~3000 characters of readable text."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "Full URL including https://, e.g. https://orf.at"
                }
            },
            "required": ["url"]
        }
    }
}


def _strip_html(html: str) -> str:
    """Very lightweight HTML → plain text (no dependencies)."""
    # Remove scripts and style blocks
    html = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', html, flags=re.S | re.I)
    # Remove tags
    html = re.sub(r'<[^>]+>', ' ', html)
    # Decode common entities
    for ent, char in [('&amp;','&'),('&lt;','<'),('&gt;','>'),
                      ('&nbsp;',' '),('&quot;','"'),('&#39;',"'")]:
        html = html.replace(ent, char)
    # Collapse whitespace
    html = re.sub(r'[ \t]+', ' ', html)
    html = re.sub(r'\n{3,}', '\n\n', html)
    return html.strip()


def run(url: str, max_chars: int = 3000) -> dict[str, Any]:
    """Fetch URL and return {url, title, text, error}."""
    headers = {
        "User-Agent": "Mozilla/5.0 (local-ai-stack/1.0; +https://github.com/KonradLanz/local-ai-stack)",
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "de-AT,de;q=0.9,en;q=0.8",
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            charset = "utf-8"
            ct = resp.headers.get_content_charset()
            if ct:
                charset = ct
            html = resp.read().decode(charset, errors="replace")

        # Extract title
        title_m = re.search(r'<title[^>]*>([^<]+)</title>', html, re.I)
        title = title_m.group(1).strip() if title_m else url

        text = _strip_html(html)[:max_chars]
        if len(_strip_html(html)) > max_chars:
            text += f"\n\n[... truncated at {max_chars} chars ...]"

        return {"url": url, "title": title, "text": text, "error": None}

    except urllib.error.HTTPError as e:
        return {"url": url, "title": "", "text": "", "error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"url": url, "title": "", "text": "", "error": str(e)}


if __name__ == "__main__":
    import sys
    result = run(sys.argv[1] if len(sys.argv) > 1 else "https://orf.at")
    print(json.dumps(result, ensure_ascii=False, indent=2))
