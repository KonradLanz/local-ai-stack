"""
cluster/discover.py — Node Discovery Daemon
Probes all configured nodes and builds a live capability map.
Used by the load-balancer (cluster/proxy.py) to route inference requests.
License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG

Runs as a background daemon on the coordinator (PRIMARY) node.
Also usable as a CLI tool: python cluster/discover.py --once
"""

import argparse
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

try:
    import yaml
    _YAML = True
except ImportError:
    _YAML = False

log = logging.getLogger("discover")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

NETWORK_MAP = Path(__file__).parent / "network-map.yaml"
LIVE_NODES_OUT = Path(__file__).parent / "live-nodes.json"
PROBE_INTERVAL = int(os.environ.get("DISCOVER_INTERVAL", "30"))  # seconds


def load_network_map() -> dict:
    if not NETWORK_MAP.exists():
        log.error("network-map.yaml not found at %s", NETWORK_MAP)
        sys.exit(1)
    if _YAML:
        with open(NETWORK_MAP) as f:
            return yaml.safe_load(f)
    # Fallback: minimal JSON-ish parsing not implemented — require pyyaml
    log.error("pyyaml not installed. Run: pip install pyyaml")
    sys.exit(1)


def probe_node(node: dict, timeout: int = 4) -> dict:
    """
    Probes a node's Ollama API for health and available models.
    Returns enriched node dict with 'status', 'models', 'latency_ms'.
    """
    ip = node["ip"]
    port = node.get("ollama_port", 11434)
    base_url = f"http://{ip}:{port}"
    result = {**node, "status": "offline", "models": [], "latency_ms": None}

    try:
        t0 = time.monotonic()
        # Health check
        req = urllib.request.Request(f"{base_url}/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
        latency = int((time.monotonic() - t0) * 1000)
        models = [m["name"] for m in data.get("models", [])]
        result.update({"status": "online", "models": models, "latency_ms": latency,
                       "base_url": base_url})
        log.info("  ✓ %s (%s) — %d models, %dms", node["name"], ip, len(models), latency)
    except urllib.error.URLError:
        log.info("  ✗ %s (%s) — offline", node["name"], ip)
    except Exception as e:  # noqa: BLE001
        log.warning("  ? %s (%s) — error: %s", node["name"], ip, e)

    return result


def discover_once(network_map: dict) -> dict:
    """Probes all enabled nodes and returns the live capability map."""
    nodes = [n for n in network_map.get("nodes", []) if n.get("enabled", True)]
    log.info("Probing %d node(s)...", len(nodes))

    results = [probe_node(n) for n in nodes]

    online = [r for r in results if r["status"] == "online"]
    offline = [r for r in results if r["status"] != "online"]

    # Sort online nodes by profile priority: primary > secondary > thin
    priority = {"primary": 0, "secondary": 1, "thin-worker": 2}
    online.sort(key=lambda n: priority.get(n.get("profile", "thin-worker"), 9))

    live_map = {
        "cluster_name": network_map.get("cluster_name"),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "online": online,
        "offline": offline,
        "coordinator": online[0] if online else None,
    }

    LIVE_NODES_OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(LIVE_NODES_OUT, "w") as f:
        json.dump(live_map, f, indent=2)
    log.info("Live map written: %s (%d online, %d offline)",
             LIVE_NODES_OUT, len(online), len(offline))
    return live_map


def daemon_loop():
    """Runs discover_once every PROBE_INTERVAL seconds."""
    network_map = load_network_map()
    log.info("Discovery daemon starting. Interval: %ds", PROBE_INTERVAL)
    while True:
        try:
            discover_once(network_map)
        except Exception as e:  # noqa: BLE001
            log.error("Probe cycle failed: %s", e)
        time.sleep(PROBE_INTERVAL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="local-ai-stack node discovery")
    parser.add_argument("--once", action="store_true", help="Probe once and exit")
    parser.add_argument("--interval", type=int, default=PROBE_INTERVAL,
                        help=f"Probe interval in seconds (default {PROBE_INTERVAL})")
    args = parser.parse_args()
    PROBE_INTERVAL = args.interval

    if args.once:
        nm = load_network_map()
        result = discover_once(nm)
        print(json.dumps(result, indent=2))
    else:
        daemon_loop()
