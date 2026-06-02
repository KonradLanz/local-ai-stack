"""
mesh/scheduler.py — Mesh task scheduler
Scores candidate nodes and routes each task to the optimal one.
Runs on the coordinator node; all other nodes submit here.
Copyright 2026 GrEEV.com KG

Routing score formula:
  score = capacity_score  * 0.40
        + availability_score * 0.30
        + specialization_score * 0.20
        + latency_score      * 0.10
"""

import json
import logging
import time
import urllib.error
import urllib.request
from typing import Optional

from mesh.classifier import classify
from mesh.state import load_state

log = logging.getLogger("mesh.scheduler")

# Rough token-to-MB estimate: 1 token ≈ 0.002 MB in context window
TOKENS_PER_MB = 500
# Minimum inference_mb to consider a node for a task
MIN_INFERENCE_MB = 512


def _capacity_score(node: dict, prompt_len: int) -> float:
    avail  = node.get("inference_mb_available", node.get("inference_mb", 0))
    needed = max(prompt_len // TOKENS_PER_MB, 512)
    if avail < MIN_INFERENCE_MB:
        return 0.0
    return min(avail / max(needed, 1), 1.0)


def _availability_score(node: dict) -> float:
    return max(0.0, 1.0 - node.get("load", 0.0))


def _specialization_score(node: dict, task_type: str) -> float:
    specs = node.get("specializations", {})
    return float(specs.get(task_type, 0.0))


def _latency_score(node: dict) -> float:
    ms = node.get("latency_ms", 500)
    if not ms or ms <= 0:
        return 0.0
    return min(100 / ms, 1.0)  # 100ms → 1.0, 1000ms → 0.1


def score_node(node: dict, task_type: str, prompt_len: int) -> float:
    if node.get("status") != "online":
        return -1.0
    return (
        _capacity_score(node, prompt_len)        * 0.40 +
        _availability_score(node)                * 0.30 +
        _specialization_score(node, task_type)   * 0.20 +
        _latency_score(node)                     * 0.10
    )


def pick_node(prompt: str, task_type: Optional[str] = None) -> Optional[dict]:
    """
    Given a prompt, classify the task type, score all online nodes,
    return the best node dict or None if nothing is available.
    """
    state = load_state()
    nodes = state.get("nodes", [])

    if not task_type:
        classification = classify(prompt)
        task_type = classification["task_type"]
        log.debug("Task classified as: %s (%.2f)", task_type,
                  classification["confidence"])

    prompt_len = len(prompt)
    scored = []
    for node in nodes:
        s = score_node(node, task_type, prompt_len)
        scored.append((s, node))
        log.debug("  %s → score %.3f", node["name"], s)

    scored.sort(key=lambda x: x[0], reverse=True)
    best_score, best_node = scored[0] if scored else (-1.0, None)

    if best_score <= 0 or best_node is None:
        log.warning("No suitable node found for task_type=%s", task_type)
        return None

    log.info("Routing %s → %s (score=%.3f)", task_type, best_node["name"], best_score)
    return best_node


def forward_to_node(node: dict, payload: dict) -> dict:
    """
    Forward an Ollama-compatible /api/chat or /api/generate request
    to the chosen node's Ollama endpoint. Returns the response dict.
    """
    ip   = node["ip"]
    port = node.get("ollama_port", 11434)
    path = payload.get("_path", "/api/chat")
    url  = f"http://{ip}:{port}{path}"

    # Remove internal routing fields before forwarding
    clean_payload = {k: v for k, v in payload.items() if not k.startswith("_")}
    body = json.dumps(clean_payload).encode()

    t0 = time.monotonic()
    try:
        req = urllib.request.Request(
            url, data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read())
        result["_routed_to"] = node["name"]
        result["_duration_ms"] = int((time.monotonic() - t0) * 1000)
        return result
    except urllib.error.URLError as e:
        log.error("Forward to %s failed: %s", node["name"], e)
        return {"error": str(e), "_routed_to": node["name"]}
