"""
cluster/discover.py — Node Discovery Daemon
Probes all configured nodes and builds a live capability map.
License: AGPL-3.0-or-later — Copyright 2026 GrEEV.com KG

Zero external dependencies: reads network-map.json (stdlib json).
YAML support is opportunistic — used only if pyyaml is installed.

CLI:
  python3 cluster/discover.py --once     # single probe, print JSON
  python3 cluster/discover.py            # daemon loop (30s interval)
  DISCOVER_INTERVAL=10 python3 cluster/discover.py
"""

import argparse
import json
import logging
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

log = logging.getLogger("discover")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

_DIR            = Path(__file__).parent
PROBE_INTERVAL  = int(os.environ.get("DISCOVER_INTERVAL", "30"))
LIVE_NODES_OUT  = _DIR / "live-nodes.json"

_MAP_CANDIDATES = [
    _DIR / "network-map.json",
    _DIR / "network-map.yaml",
    _DIR / "network-map.json.example",
]


def load_network_map() -> dict:
    """Load network map from disk. Called every probe cycle so edits take effect immediately."""
    for path in _MAP_CANDIDATES:
        if not path.exists():
            continue
        if path.suffix == ".json":
            with open(path) as f:
                data = json.load(f)
            if path.name.endswith(".example"):
                log.warning("Using example network map — copy to network-map.json and set real IPs")
            else:
                log.debug("Network map: %s", path.name)
            return data
        if path.suffix == ".yaml":
            try:
                import yaml
                with open(path) as f:
                    data = yaml.safe_load(f)
                log.debug("Network map: %s (pyyaml)", path.name)
                return data
            except ImportError:
                log.warning(
                    "%s found but pyyaml not installed. "
                    "Run: pip install pyyaml  or create cluster/network-map.json",
                    path.name
                )
                continue
    log.error(
        "No network map found. "
        "Copy cluster/network-map.json.example \u2192 cluster/network-map.json "
        "and fill in your IPs."
    )
    raise SystemExit(1)


def probe_node(node: dict, timeout: int = 4) -> dict:
    ip       = node["ip"]
    port     = node.get("ollama_port", 11434)
    base_url = f"http://{ip}:{port}"
    result   = {**node, "status": "offline", "models": [], "latency_ms": None}
    try:
        t0 = time.monotonic()
        with urllib.request.urlopen(
            urllib.request.Request(f"{base_url}/api/tags"), timeout=timeout
        ) as resp:
            data = json.loads(resp.read())
        latency = int((time.monotonic() - t0) * 1000)
        models  = [m["name"] for m in data.get("models", [])]
        result.update({"status": "online", "models": models,
                       "latency_ms": latency, "base_url": base_url})
        log.info("  \u2713 %s (%s) \u2014 %d models, %dms", node["name"], ip, len(models), latency)
    except urllib.error.URLError:
        log.info("  \u2717 %s (%s) \u2014 offline", node["name"], ip)
    except Exception as e:
        log.warning("  ? %s (%s) \u2014 %s", node["name"], ip, e)
    return result


def discover_once(network_map: dict) -> dict:
    nodes   = [n for n in network_map.get("nodes", []) if n.get("enabled", True)]
    log.info("Probing %d node(s)...", len(nodes))
    results = [probe_node(n) for n in nodes]
    online  = sorted(
        [r for r in results if r["status"] == "online"],
        key=lambda n: {"primary": 0, "secondary": 1, "qnap": 2}.get(n.get("profile", ""), 9)
    )
    offline = [r for r in results if r["status"] != "online"]
    live_map = {
        "cluster_name": network_map.get("cluster_name"),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "online":      online,
        "offline":     offline,
        "coordinator": online[0] if online else None,
    }
    LIVE_NODES_OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(LIVE_NODES_OUT, "w") as f:
        json.dump(live_map, f, indent=2)
    log.info("Live map: %d online, %d offline", len(online), len(offline))
    return live_map


def daemon_loop():
    log.info("Discovery daemon — interval %ds (reloads map each cycle)", PROBE_INTERVAL)
    while True:
        try:
            # Reload map from disk every cycle — edits take effect without restart
            network_map = load_network_map()
            discover_once(network_map)
        except SystemExit:
            raise
        except Exception as e:
            log.error("Probe cycle: %s", e)
        time.sleep(PROBE_INTERVAL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--once",     action="store_true",
                        help="Single probe cycle, print JSON, then exit")
    parser.add_argument("--interval", type=int, default=PROBE_INTERVAL,
                        help=f"Probe interval in seconds (default {PROBE_INTERVAL})")
    args = parser.parse_args()
    PROBE_INTERVAL = args.interval
    if args.once:
        print(json.dumps(discover_once(load_network_map()), indent=2))
    else:
        daemon_loop()
