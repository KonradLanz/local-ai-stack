"""
mesh/node.py — Per-node mesh daemon
Runs on every machine. Exposes /mesh/* HTTP endpoints.
Copyright 2026 GrEEV.com KG

Endpoints:
  GET  /mesh/status      — node capabilities + load
  GET  /mesh/nodes       — known mesh nodes (gossip)
  POST /mesh/submit      — submit a task to the mesh
  GET  /mesh/suggestions — pending model swap suggestions
  POST /mesh/apply       — accept/reject a suggestion

Dependencies: standard library only.
"""

import http.server
import json
import logging
import os
import socket
import threading
import time
from pathlib import Path

log = logging.getLogger("mesh.node")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

REPO_ROOT     = Path(__file__).parent.parent
MESH_PORT     = int(os.environ.get("MESH_PORT", "11430"))
_active_tasks = 0
_active_lock  = threading.Lock()


def load_hw_profile() -> dict:
    p = REPO_ROOT / "cluster" / "hw-profile.json"
    return json.loads(p.read_text()) if p.exists() else {}


class ReuseAddrHTTPServer(http.server.HTTPServer):
    """HTTPServer with SO_REUSEADDR so restart after crash never hits EADDRINUSE."""
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()


class MeshHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(fmt, *args)

    def _json(self, code: int, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length)) if length > 0 else {}

    def do_GET(self):
        if self.path == "/mesh/status":
            self._handle_status()
        elif self.path == "/mesh/nodes":
            self._handle_nodes()
        elif self.path == "/mesh/suggestions":
            self._handle_suggestions()
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/mesh/submit":
            self._handle_submit()
        elif self.path == "/mesh/apply":
            self._handle_apply()
        else:
            self._json(404, {"error": "not found"})

    def _handle_status(self):
        global _active_tasks
        hw = load_hw_profile()
        inference_mb = hw.get("inference_mb", 0)
        with _active_lock:
            load = min(_active_tasks * 0.30, 1.0)
        available = int(inference_mb * (1.0 - load))
        from mesh.specialist import get_specialization_scores
        scores = {s["task_type"]: s["score"]
                  for s in get_specialization_scores(hw.get("node_profile", "unknown"))}
        self._json(200, {
            "node_profile":           hw.get("node_profile"),
            "inference_mb":           inference_mb,
            "inference_mb_available": available,
            "load":                   load,
            "active_tasks":           _active_tasks,
            "specializations":        scores,
            "ts":                     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

    def _handle_nodes(self):
        from mesh.state import load_state
        self._json(200, load_state().get("nodes", []))

    def _handle_submit(self):
        global _active_tasks
        payload   = self._read_body()
        prompt    = self._extract_prompt(payload)
        task_type = payload.get("_task_type")
        from mesh.scheduler import pick_node, forward_to_node
        node = pick_node(prompt, task_type)
        if not node:
            self._json(503, {"error": "No suitable node available"})
            return
        with _active_lock:
            _active_tasks += 1
        t0 = time.monotonic()
        try:
            result = forward_to_node(node, payload)
        finally:
            with _active_lock:
                _active_tasks -= 1
        duration_ms = int((time.monotonic() - t0) * 1000)
        from mesh.classifier import classify
        from mesh.specialist import record_task, init_db
        init_db()
        classification = classify(prompt)
        tokens = result.get("eval_count", len(prompt) // 4)
        record_task(
            task_type   = classification["task_type"],
            routed_to   = node["name"],
            model       = payload.get("model", "unknown"),
            prompt_len  = len(prompt),
            tokens_gen  = tokens,
            duration_ms = duration_ms,
        )
        self._json(200, result)

    def _handle_suggestions(self):
        from mesh.specialist import get_pending_suggestions, init_db
        init_db()
        self._json(200, get_pending_suggestions())

    def _handle_apply(self):
        import sqlite3
        from mesh.specialist import DB_PATH, init_db
        init_db()
        body = self._read_body()
        suggestion_id = body.get("id")
        action = body.get("action")
        if not suggestion_id or action not in ("accept", "reject"):
            self._json(400, {"error": "id and action (accept|reject) required"})
            return
        conn = sqlite3.connect(DB_PATH)
        row = conn.execute(
            "SELECT node, to_model FROM model_suggestions WHERE id=?",
            (suggestion_id,)
        ).fetchone()
        if not row:
            conn.close()
            self._json(404, {"error": "suggestion not found"})
            return
        node_name, to_model = row
        status = "accepted" if action == "accept" else "rejected"
        conn.execute("UPDATE model_suggestions SET status=? WHERE id=?",
                     (status, suggestion_id))
        conn.commit()
        conn.close()
        if action == "accept":
            threading.Thread(target=self._pull_model, args=(to_model,), daemon=True).start()
            self._json(200, {"status": "accepted", "pulling": to_model})
        else:
            self._json(200, {"status": "rejected"})

    def _pull_model(self, model: str):
        import subprocess
        log.info("Pulling model: %s", model)
        subprocess.run(["ollama", "pull", model], check=False)
        log.info("Model pull complete: %s", model)

    @staticmethod
    def _extract_prompt(payload: dict) -> str:
        msgs = payload.get("messages", [])
        if msgs:
            return " ".join(m.get("content", "") for m in msgs if isinstance(m, dict))
        return payload.get("prompt", "")


def run(port: int = MESH_PORT):
    server = ReuseAddrHTTPServer(("", port), MeshHandler)
    log.info("Mesh node listening on :%d (SO_REUSEADDR)", port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Mesh node shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    from mesh.specialist import init_db
    init_db()
    run()
