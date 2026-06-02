"""
fetch_url — Open WebUI Tool
Fetches a URL and returns clean Markdown content.
License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG

Compatible with: Open WebUI tool interface, LangChain, standalone.
"""

import re
import urllib.request
import urllib.error
from html.parser import HTMLParser


class _TextExtractor(HTMLParser):
    """Minimal HTML -> plain text extractor with no dependencies."""
    SKIP_TAGS = {"script", "style", "noscript", "head", "meta", "link"}

    def __init__(self):
        super().__init__()
        self._skip = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() in self.SKIP_TAGS:
            self._skip += 1
        if tag.lower() in {"p", "br", "h1", "h2", "h3", "h4", "li", "tr"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag.lower() in self.SKIP_TAGS:
            self._skip = max(0, self._skip - 1)

    def handle_data(self, data):
        if self._skip == 0 and data.strip():
            self.parts.append(data)


def fetch_url(url: str, max_chars: int = 8000) -> str:
    """
    Fetches the given URL and returns its text content as plain text.
    For HTML pages, script/style blocks are stripped. For plain text
    and Markdown files the content is returned as-is.

    Args:
        url: The URL to fetch (http or https).
        max_chars: Maximum characters to return (default 8000).

    Returns:
        Extracted text content, truncated to max_chars.
    """
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "local-ai-stack/1.0 (fetch_url tool; +https://github.com/KonradLanz/local-ai-stack)"
            },
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            content_type = resp.headers.get("Content-Type", "")
            raw = resp.read()

        # Try UTF-8, fall back to latin-1
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("latin-1", errors="replace")

        if "text/html" in content_type:
            parser = _TextExtractor()
            parser.feed(text)
            text = " ".join(parser.parts)
            # Collapse whitespace
            text = re.sub(r"[ \t]+", " ", text)
            text = re.sub(r"\n{3,}", "\n\n", text).strip()

        if len(text) > max_chars:
            text = text[:max_chars] + f"\n\n[... truncated at {max_chars} chars]"

        return text

    except urllib.error.HTTPError as e:
        return f"[fetch_url error] HTTP {e.code} {e.reason} for {url}"
    except urllib.error.URLError as e:
        return f"[fetch_url error] Could not reach {url}: {e.reason}"
    except Exception as e:  # noqa: BLE001
        return f"[fetch_url error] {type(e).__name__}: {e}"
