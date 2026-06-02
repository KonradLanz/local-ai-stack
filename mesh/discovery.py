"""
mesh/discovery.py — Full-mesh gossip discovery + coordinator election
Copyright 2026 GrEEV.com KG

Zero external dependencies. JSON primary, YAML opportunistic.
Same load_network_map() contract as cluster/discover.py.
"""

import argparse
import json
import logging
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

log = logging.getLogger("mesh.discovery")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

REPO_ROOT       = Path(__file__).parent.parent
PROBE_INTERVAL  = int(os.environ.get("MESH_PROBE_INTERVAL", "15"))
HEARTBEAT_TTL   = int(os.environ.get("MESH_HEARTBEAT_TTL",  "45"))

_MAP_CANDIDATES = [
    REPO_ROOT / "cluster" / "network-map.json",
    REPO_ROOT / "cluster" / "network-map.yaml",
    REPO_ROOT / "cluster" / "network-map.json.example",
]


def load_network_map() -> dict:
    for path in _MAP_CANDIDATES:
        if not path.exists():
            continue
        if path.suffix == ".json":
            with open(path) as f:
                data = json.load(f)
            if path.name.endswith(".example"):
                log.warning("Using example network map — set real IPs in cluster/network-map.json")
            return data
        if path.suffix == ".yaml":
            try:
                import yaml
                with open(path) as f:
                    return yaml.safe_load(f)
            except ImportError:
                log.warning("network-map.yaml found but pyyaml not installed — skipping")
                continue
    log.error("No network map. Copy cluster/network-map.json.example → cluster/network-map.json")
    raise SystemExit(1)


def load_local_hw_profile() -> dict:
    p = REPO_ROOT / "cluster" / "hw-profile.json"
    return json.loads(p.read_text()) if p.exists() else {}


def probe_node(node: dict, timeout: int = 4) -> dict:
    ip, port = node["ip"], node.get("ollama_port", 11434)
    result = {**node, "status": "offline", "models": [],
              "latency_ms": None, "last_seen": 0}
    try:
        t0 = time.monotonic()
        with urllib.request.urlopen(
            urllib.request.Request(f"http://{ip}:{port}/api/tags"), timeout=timeout
        ) as r:
            data = json.loads(r.read())
        latency = int((time.monotonic() - t0) * 1000)
        result.update({
            "status": "online",
            "models": [m["name"] for m in data.get("models", [])],
            "latency_ms": latency,
            "last_seen": time.time(),
        })
        log.info("  ✓ %s (%s) — %d models, %dms",
                 node["name"], ip, len(result["models"]), latency)
    except Exception:
        log.info("  ✗ %s (%s) — offline", node["name"], ip)

    # Enrich with mesh daemon status if available
    mesh_port = node.get("mesh_port", 11430)
    try:
        with urllib.request.urlopen(
            urllib.request.Request(f"http://{ip}:{mesh_port}/mesh/status"), timeout=2
        ) as r:
            md = json.loads(r.read())
        result.update({
            "inference_mb":           md.get("inference_mb", node.get("inference_mb", 0)),
            "inference_mb_available": md.get("inference_mb_available", 0),
            "load":                   md.get("load", 0.0),
            "specializations":        md.get("specializations", {}),
        })
    except Exception:
        pass
    return result


def merge_gossip(local: list, remote: list) -> list:
    merged = {n["name"]: n for n in local}
    for n in remote:
        name = n.get("name")
        if not name:
            continue
        if name not in merged or n.get("last_seen", 0) > merged[name].get("last_seen", 0):
            merged[name] = n
    return list(merged.values())


def discover_once(network_map: dict, local_hw: dict) -> dict:
    from mesh.state import save_state, elect_coordinator
    nodes  = [n for n in network_map.get("nodes", []) if n.get("enabled", True)]
    probed = [probe_node(n) for n in nodes]

    # Gossip: merge views from online peers
    for node in [n for n in probed if n["status"] == "online"]:
        try:
            with urllib.request.urlopen(
                urllib.request.Request(
                    f"http://{node['ip']}:{node.get('mesh_port', 11430)}/mesh/nodes"
                ), timeout=2
            ) as r:
                probed = merge_gossip(probed, json.loads(r.read()))
        except Exception:
            pass

    coordinator = elect_coordinator(probed)
    state = {
        "cluster_name":   network_map.get("cluster_name", "local-ai-mesh"),
        "nodes":          probed,
        "coordinator":    coordinator["name"] if coordinator else None,
        "coordinator_ip": coordinator["ip"]   if coordinator else None,
    }
    save_state(state)
    online = sum(1 for n in probed if n["status"] == "online")
    log.info("Mesh: %d/%d online. Coordinator: %s",
             online, len(probed), coordinator["name"] if coordinator else "NONE")
    return state


def daemon_loop(network_map: dict, local_hw: dict):
    log.info("Mesh discovery daemon — interval %ds", PROBE_INTERVAL)
    while True:
        try:
            discover_once(network_map, local_hw)
        except Exception as e:
            log.error("Discovery cycle: %s", e)
        time.sleep(PROBE_INTERVAL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=int, default=PROBE_INTERVAL)
    args = parser.parse_args()
    PROBE_INTERVAL = args.interval
    nm = load_network_map()
    hw = load_local_hw_profile()
    if args.once:
        print(json.dumps(discover_once(nm, hw), indent=2))
    else:
        daemon_loop(nm, hw)
