"""
mesh/state.py — Mesh state management
Reads/writes mesh-state.json, the shared view of the mesh.
Copyright 2026 GrEEV.com KG
"""

import json
import time
from pathlib import Path
from typing import Optional

STATE_FILE = Path(__file__).parent.parent / "data" / "mesh-state.json"


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {"nodes": [], "coordinator": None, "updated_at": None}


def save_state(state: dict):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    state["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def get_coordinator(state: dict) -> Optional[dict]:
    """Return the current coordinator node dict, or None."""
    coord_name = state.get("coordinator")
    if not coord_name:
        return None
    for node in state.get("nodes", []):
        if node.get("name") == coord_name and node.get("status") == "online":
            return node
    return None


def elect_coordinator(nodes: list) -> Optional[dict]:
    """
    Elect coordinator: highest inference_mb among online nodes.
    Returns the winning node dict or None if no nodes online.
    """
    online = [n for n in nodes if n.get("status") == "online"]
    if not online:
        return None
    return max(online, key=lambda n: n.get("inference_mb", 0))
