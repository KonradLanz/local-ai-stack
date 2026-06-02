"""
perplexity_search — Open WebUI Tool
Searches the web via Perplexity's Search API.
License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG

Dependencies: httpx (pip install httpx)
API docs: https://docs.perplexity.ai/docs/search/quickstart

The model calls this tool when it needs real-time or external information
that is not available in its local context or uploaded documents.
Local processing is always preferred; this is the fallback.
"""

import json
import os

try:
    import httpx
    _HTTPX_AVAILABLE = True
except ImportError:
    _HTTPX_AVAILABLE = False
    import urllib.request
    import urllib.error


PERPLEXITY_API_URL = "https://api.perplexity.ai/search"


def perplexity_search(
    query: str,
    max_results: int = 5,
    search_recency: str = "month",
) -> str:
    """
    Searches the web using Perplexity's Search API and returns a summary
    with citations. Use this tool only for real-time or factual queries
    that cannot be answered from the current context.

    IMPORTANT: All queries pass through the IPR filter before being sent.
    Do NOT send queries containing personal data, internal project names,
    or confidential information.

    Args:
        query: The search query (will be screened by IPR filter).
        max_results: Number of results to return (1-10, default 5).
        search_recency: Recency filter — "day", "week", "month", "year".

    Returns:
        Search results with titles, URLs, and summary snippets.
    """
    api_key = os.environ.get("PERPLEXITY_API_KEY", "").strip()
    if not api_key:
        return (
            "[perplexity_search] No API key configured. "
            "Set PERPLEXITY_API_KEY in .env to enable web search."
        )

    # Run IPR filter on the query before sending externally
    filtered_query = _apply_ipr_filter(query)
    if filtered_query is None:
        return (
            "[perplexity_search] Query blocked by IPR filter: "
            "contains potentially sensitive information. "
            "Rephrase without internal or personal data."
        )

    model = os.environ.get("PERPLEXITY_MODEL", "sonar")
    payload = {
        "query": filtered_query,
        "max_results": max(1, min(10, max_results)),
        "search_recency_filter": search_recency,
        "model": model,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": "local-ai-stack/1.0 (+https://github.com/KonradLanz/local-ai-stack)",
    }

    try:
        if _HTTPX_AVAILABLE:
            with httpx.Client(timeout=20) as client:
                resp = client.post(PERPLEXITY_API_URL, json=payload, headers=headers)
            resp.raise_for_status()
            data = resp.json()
        else:
            req = urllib.request.Request(
                PERPLEXITY_API_URL,
                data=json.dumps(payload).encode(),
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read())

        return _format_results(data, filtered_query)

    except Exception as e:  # noqa: BLE001
        return f"[perplexity_search error] {type(e).__name__}: {e}"


def _format_results(data: dict, query: str) -> str:
    results = data.get("results", [])
    if not results:
        return f"No results found for: {query}"

    lines = [f"**Web search results for:** {query}\n"]
    for i, r in enumerate(results, 1):
        title = r.get("title", "(no title)")
        url = r.get("url", "")
        snippet = r.get("snippet", r.get("content", ""))[:400]
        lines.append(f"{i}. **{title}**  ")
        if url:
            lines.append(f"   {url}  ")
        if snippet:
            lines.append(f"   {snippet}")
        lines.append("")
    return "\n".join(lines)


def _apply_ipr_filter(query: str) -> str | None:
    """
    Inline lightweight IPR filter.
    For full filtering, ipr_filter.py handles this as a pre-processor.
    Returns the (possibly redacted) query, or None if blocked.
    """
    ipr_enabled = os.environ.get("IPR_FILTER_ENABLED", "true").lower() == "true"
    if not ipr_enabled:
        return query

    # Load policy config for patterns if available
    try:
        from tools.ipr_filter import screen_query  # type: ignore
        return screen_query(query)
    except ImportError:
        pass

    # Fallback: basic pattern check
    import re
    # Block obvious personal data patterns
    patterns = [
        r"\b[A-Z][a-z]+ [A-Z][a-z]+\b",           # Full names (heuristic)
        r"\b\d{4}[\s-]\d{4}[\s-]\d{4}[\s-]\d{4}\b", # Card numbers
        r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b",       # IBAN
    ]
    for pat in patterns:
        if re.search(pat, query):
            return None  # Block
    return query
