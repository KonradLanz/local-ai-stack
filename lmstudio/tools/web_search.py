# =============================================================================
# lmstudio/tools/web_search.py
# Tool: DuckDuckGo Instant Answer + HTML scrape (no API key needed)
# For Perplexity Search API: set PERPLEXITY_API_KEY env var.
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
import os, urllib.request, urllib.parse, re, json
from typing import Any

DEFINITION = {
    "type": "function",
    "function": {
        "name": "web_search",
        "description": (
            "Search the web for current information. "
            "Use this when the user asks about news, current events, prices, "
            "or anything that might have changed recently."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query in natural language"
                },
                "max_results": {
                    "type": "integer",
                    "description": "Number of results to return (default 5)",
                    "default": 5
                }
            },
            "required": ["query"]
        }
    }
}


def _ddg_search(query: str, max_results: int = 5) -> list[dict]:
    """DuckDuckGo HTML scrape — no API key, rate-limited but fine for personal use."""
    url = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": query})
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "Accept-Language": "de-AT,de;q=0.9,en;q=0.8",
    }
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        html = resp.read().decode("utf-8", errors="replace")

    results = []
    # Parse result blocks
    blocks = re.findall(
        r'<a[^>]+class="result__a"[^>]*href="([^"]+)"[^>]*>([^<]+)</a>.*?'
        r'<a[^>]+class="result__snippet"[^>]*>([^<]*(?:<[^>]+>[^<]*)*)</a>',
        html, re.S
    )
    for href, title, snippet in blocks[:max_results]:
        # DDG redirects: extract actual URL
        qs = urllib.parse.urlparse(href).query
        params = urllib.parse.parse_qs(qs)
        actual_url = params.get("uddg", [href])[0]
        clean_snippet = re.sub(r'<[^>]+>', '', snippet).strip()
        results.append({"title": title.strip(), "url": actual_url, "snippet": clean_snippet})

    return results


def _perplexity_search(query: str, max_results: int = 5) -> list[dict]:
    """Perplexity Search API — requires PERPLEXITY_API_KEY env var."""
    api_key = os.environ["PERPLEXITY_API_KEY"]
    payload = json.dumps({
        "query": query,
        "max_results": max_results,
        "search_recency_filter": "month"
    }).encode()
    req = urllib.request.Request(
        "https://api.perplexity.ai/search",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    results = []
    for r in data.get("results", [])[:max_results]:
        results.append({
            "title": r.get("title", ""),
            "url": r.get("url", ""),
            "snippet": r.get("content", "")[:400]
        })
    return results


def run(query: str, max_results: int = 5) -> dict[str, Any]:
    """Run search — Perplexity if API key set, else DuckDuckGo."""
    try:
        if os.environ.get("PERPLEXITY_API_KEY"):
            results = _perplexity_search(query, max_results)
            source = "perplexity"
        else:
            results = _ddg_search(query, max_results)
            source = "duckduckgo"
        return {"query": query, "source": source, "results": results, "error": None}
    except Exception as e:
        return {"query": query, "source": "error", "results": [], "error": str(e)}


if __name__ == "__main__":
    import sys
    q = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Wetter Wien heute"
    print(json.dumps(run(q), ensure_ascii=False, indent=2))
