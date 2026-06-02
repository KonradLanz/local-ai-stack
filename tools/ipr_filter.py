"""
ipr_filter — IPR Privacy Filter for local-ai-stack
Screens outgoing queries to public AI APIs for sensitive/confidential content.
License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG

This module:
  1. Loads sensitivity patterns from config/ipr_policy.yaml
  2. Classifies queries using rule-based matching (fast, always-on)
  3. Optionally routes borderline queries to the local LLM for classification
  4. Returns sanitized query or blocks entirely
  5. Logs blocked queries locally (never externally)

Usage as Open WebUI tool:
    Register ipr_filter.py as a tool. The model can call screen_query()
    explicitly, or it is called automatically by perplexity_search.

Standalone usage:
    from tools.ipr_filter import screen_query
    safe = screen_query("my query")  # returns None if blocked
"""

import logging
import os
import re
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Policy loading
# ---------------------------------------------------------------------------

def _load_policy() -> dict:
    config_path = os.environ.get("IPR_POLICY_CONFIG", "config/ipr_policy.yaml")
    path = Path(config_path)
    if not path.exists():
        return _default_policy()
    try:
        import yaml  # pip install pyyaml
        with open(path) as f:
            return yaml.safe_load(f) or _default_policy()
    except Exception:  # noqa: BLE001
        return _default_policy()


def _default_policy() -> dict:
    return {
        "sensitivity": "medium",
        "block_patterns": [
            r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b",  # Card numbers
            r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b",               # IBAN
            r"\b\d{3}-\d{2}-\d{4}\b",                           # SSN (US)
            r"password\s*[:=]\s*\S+",                            # Password leaks
            r"api[_-]?key\s*[:=]\s*\S+",                        # API keys
            r"secret\s*[:=]\s*\S+",                              # Secrets
            r"bearer\s+[a-z0-9_\-.]+",                           # Bearer tokens
        ],
        "redact_patterns": [
            r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Z|a-z]{2,}\b",  # Email
        ],
        "use_local_llm_for_borderline": False,
        "log_blocked": True,
        "log_path": "data/ipr_blocked.log",
    }


# ---------------------------------------------------------------------------
# Core filter
# ---------------------------------------------------------------------------

def screen_query(query: str) -> Optional[str]:
    """
    Screens a query before it is sent to a public AI API.

    Returns:
        - The original query if clean
        - A redacted version if mild patterns are found
        - None if the query should be blocked entirely

    This function is safe to call from perplexity_search and any
    other tool that sends data externally.
    """
    ipr_enabled = os.environ.get("IPR_FILTER_ENABLED", "true").lower() == "true"
    if not ipr_enabled:
        return query

    policy = _load_policy()
    sensitivity = os.environ.get("IPR_SENSITIVITY", policy.get("sensitivity", "medium"))

    # 1. Hard block patterns
    for pat in policy.get("block_patterns", []):
        if re.search(pat, query, re.IGNORECASE):
            _log_blocked(query, pat, policy)
            return None

    # 2. Redact patterns (replace match with placeholder)
    redacted = query
    for pat in policy.get("redact_patterns", []):
        redacted = re.sub(pat, "[REDACTED]", redacted, flags=re.IGNORECASE)

    # 3. High sensitivity: also block if query looks like internal content
    if sensitivity == "high":
        internal_signals = [
            r"\binternal\b", r"\bconfidential\b", r"\bpropriet", r"\bunder\s+nda\b",
            r"\btrade\s+secret\b", r"\bnot\s+for\s+distribution\b",
        ]
        for sig in internal_signals:
            if re.search(sig, query, re.IGNORECASE):
                _log_blocked(query, sig, policy)
                return None

    # 4. Optional: route borderline queries to local LLM
    if policy.get("use_local_llm_for_borderline") and redacted != query:
        verdict = _ask_local_llm(redacted)
        if verdict == "block":
            _log_blocked(query, "local_llm_classification", policy)
            return None

    return redacted


def screen_query_tool(query: str) -> str:
    """
    Open WebUI tool wrapper for screen_query.
    Call this to explicitly check if a query is safe to send externally.

    Args:
        query: The query text to screen.

    Returns:
        The safe (possibly redacted) query, or a block message.
    """
    result = screen_query(query)
    if result is None:
        return "[IPR_FILTER_BLOCKED] This query contains potentially sensitive information and was not sent externally."
    if result != query:
        return f"[IPR_FILTER_REDACTED] Query was sanitized before external use:\n{result}"
    return f"[IPR_FILTER_CLEAN] Query is safe for external use:\n{result}"


# ---------------------------------------------------------------------------
# Local LLM classification (optional)
# ---------------------------------------------------------------------------

def _ask_local_llm(query: str) -> str:
    """
    Asks the local Ollama model whether a query contains sensitive data.
    Returns 'block' or 'allow'.
    Only called when use_local_llm_for_borderline is True in policy.
    """
    try:
        import urllib.request
        import json

        ollama_url = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
        model = os.environ.get("IPR_FILTER_MODEL", "llama3.1:8b")
        if model == "local":
            model = os.environ.get("OLLAMA_MODEL", "llama3.1:8b")

        prompt = (
            "You are a privacy classifier. Answer with exactly one word: 'block' or 'allow'.\n"
            "Block if the query contains: personal names, addresses, credentials, "
            "internal project names, financial account data, medical data, or confidential business info.\n"
            f"Query: {query[:500]}\nAnswer:"
        )
        payload = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
        req = urllib.request.Request(
            f"{ollama_url}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        answer = data.get("response", "allow").strip().lower()
        return "block" if "block" in answer else "allow"
    except Exception:  # noqa: BLE001
        return "allow"  # Fail open if local LLM unavailable


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log_blocked(query: str, pattern: str, policy: dict) -> None:
    if not policy.get("log_blocked", True):
        return
    log_path = Path(policy.get("log_path", "data/ipr_blocked.log"))
    log_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc).isoformat()
        entry = f"{ts} | pattern={pattern!r} | query={query[:200]!r}\n"
        with open(log_path, "a") as f:
            f.write(entry)
    except Exception:  # noqa: BLE001
        pass
    log.warning("IPR filter blocked outgoing query. Pattern: %s", pattern)
