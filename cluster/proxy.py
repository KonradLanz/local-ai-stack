"""
cluster/proxy.py — Intelligent Inference Load Balancer
Routes Ollama API requests to the best available cluster node.
License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG

Exposes a local Ollama-compatible API on port 11430 (configurable).
Any client (Open WebUI, LM Studio, CLI) points at this proxy instead
of a single node. The proxy selects the best node based on:
  1. Node availability (live-nodes.json, refreshed by discover.py)
  2. Model tier required (large / medium / tiny)
  3. Network latency (fastest responding primary node wins)

Usage:
  python cluster/proxy.py
  # Then set OLLAMA_BASE_URL=http://localhost:11430 in .env
"""

import json
import logging
import os
import socket
import sys
import time
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

log = logging.getLogger("proxy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

PROXY_PORT = int(os.environ.get("CLUSTER_PROXY_PORT", "11430"))
LIVE_NODES_FILE = Path(__file__).parent / "live-nodes.json"
STALE_AFTER = 90  # seconds — re-read live-nodes.json if older than this


class NodeRouter:
    """Selects the best available upstream Ollama node."""

    def __init__(self):
        self._lock = threading.Lock()
        self._nodes = []
        self._loaded_at = 0.0

    def _refresh(self):
        if time.monotonic() - self._loaded_at < STALE_AFTER:
            return
        if not LIVE_NODES_FILE.exists():
            log.warning("live-nodes.json not found. Run discover.py first.")
            return
        try:
            with open(LIVE_NODES_FILE) as f:
                data = json.load(f)
            self._nodes = data.get("online", [])
            self._loaded_at = time.monotonic()
            log.debug("Refreshed node list: %d online", len(self._nodes))
        except Exception as e:  # noqa: BLE001
            log.error("Failed to read live-nodes.json: %s", e)

    def best_node(self, model_hint: str = "") -> dict | None:
        """Returns the best node for a given model request."""
        with self._lock:
            self._refresh()
            if not self._nodes:
                return None

            # Profile priority order: primary > secondary > thin-worker
            # For tiny model names: prefer the thin node that has it loaded
            model_lower = model_hint.lower()
            tiny_keywords = ["1b", "1.5b", "3b", "phi3.5-mini", "qwen2.5:1", "deepseek-coder:1"]
            is_tiny_request = any(kw in model_lower for kw in tiny_keywords)

            if is_tiny_request:
                # Try thin workers first if they have the model
                for node in reversed(self._nodes):  # thin nodes last in sorted list
                    if node.get("profile") in ("qnap", "thin-worker", "windows-thin"):
                        if any(model_lower in m.lower() for m in node.get("models", [])):
                            return node

            # Default: return highest-priority (first) online node
            return self._nodes[0] if self._nodes else None

    def all_online(self) -> list:
        with self._lock:
            self._refresh()
            return list(self._nodes)


ROUTER = NodeRouter()


class ProxyHandler(BaseHTTPRequestHandler):
    """HTTP handler that forwards requests to the best Ollama node."""

    def log_message(self, fmt, *args):  # suppress default HTTP log noise
        log.debug(fmt, *args)

    def _forward(self, method: str, path: str, body: bytes = b""):
        # Parse model hint from JSON body if present
        model_hint = ""
        if body:
            try:
                payload = json.loads(body)
                model_hint = payload.get("model", "")
            except Exception:  # noqa: BLE001
                pass

        node = ROUTER.best_node(model_hint)
        if not node:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b'{"error":"no online cluster nodes found"}')
            log.error("No online nodes. Is discover.py running?")
            return

        upstream = f"{node['base_url']}{path}"
        log.info("%s %s → %s (%s)", method, path, node["name"], node["ip"])

        try:
            req = urllib.request.Request(upstream, data=body or None,
                                         method=method,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding",):
                        self.send_header(k, v)
                self.end_headers()
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:  # noqa: BLE001
            self.send_response(502)
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def do_GET(self):
        self._forward("GET", self.path)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward("POST", self.path, body)

    def do_DELETE(self):
        self._forward("DELETE", self.path)


def main():
    log.info("Cluster proxy starting on port %d", PROXY_PORT)
    log.info("Live nodes file: %s", LIVE_NODES_FILE)
    log.info("Point clients at: http://localhost:%d", PROXY_PORT)
    server = HTTPServer(("0.0.0.0", PROXY_PORT), ProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Proxy stopped.")


if __name__ == "__main__":
    main()
