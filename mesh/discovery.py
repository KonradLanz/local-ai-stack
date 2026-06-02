"""
mesh/discovery.py — Full-mesh gossip discovery + coordinator election
Replaces cluster/discover.py with a peer-aware mesh variant.
Copyright 2026 GrEEV.com KG

Every node runs this. Each node probes all other nodes, merges their
views (gossip), and re-elects a coordinator if the current one goes dark.

Dependencies: pyyaml (auto-installed), standard library only otherwise.
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

log = logging.getLogger("mesh.discovery")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

REPO_ROOT   = Path(__file__).parent.parent
PROBE_INTERVAL = int(os.environ.get("MESH_PROBE_INTERVAL", "15"))  # seconds
HEARTBEAT_TTL  = int(os.environ.get("MESH_HEARTBEAT_TTL", "45"))  # mark offline after N seconds


def _ensure_yaml():
    try:
        import yaml; return yaml
    except ImportError:
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "pyyaml"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            import yaml; return yaml
        except Exception:
            return None


def load_network_map() -> dict:
    yaml = _ensure_yaml()
    for candidate in [
        REPO_ROOT / "cluster" / "network-map.yaml",
        REPO_ROOT / "cluster" / "network-map.json",
    ]:
        if candidate.exists():
            with open(candidate) as f:
                return (yaml.safe_load(f) if yaml and candidate.suffix == ".yaml"
                        else json.load(f))
    log.error("No network-map found. Create cluster/network-map.yaml")
    sys.exit(1)


def load_local_hw_profile() -> dict:
    hw_file = REPO_ROOT / "cluster" / "hw-profile.json"
    if hw_file.exists():
        with open(hw_file) as f:
            return json.load(f)
    return {}


def probe_node(node: dict, timeout: int = 4) -> dict:
    """Probe a single node's Ollama + mesh endpoints."""
    ip   = node["ip"]
    port = node.get("ollama_port", 11434)
    result = {**node, "status": "offline", "models": [], "latency_ms": None,
              "load": 0.0, "inference_mb_available": 0}

    # Probe Ollama /api/tags
    try:
        t0  = time.monotonic()
        url = f"http://{ip}:{port}/api/tags"
        with urllib.request.urlopen(urllib.request.Request(url), timeout=timeout) as r:
            data = json.loads(r.read())
        latency = int((time.monotonic() - t0) * 1000)
        models  = [m["name"] for m in data.get("models", [])]
        result.update({"status": "online", "models": models, "latency_ms": latency,
                       "last_seen": time.time()})
    except Exception:
        result["last_seen"] = 0
        return result

    # Probe mesh node daemon /mesh/status (if running)
    mesh_port = node.get("mesh_port", 11430)
    try:
        url = f"http://{ip}:{mesh_port}/mesh/status"
        with urllib.request.urlopen(urllib.request.Request(url), timeout=2) as r:
            mesh_data = json.loads(r.read())
        result.update({
            "inference_mb":           mesh_data.get("inference_mb", node.get("inference_mb", 0)),
            "inference_mb_available": mesh_data.get("inference_mb_available", 0),
            "load":                   mesh_data.get("load", 0.0),
            "specializations":        mesh_data.get("specializations", {}),
        })
    except Exception:
        pass  # mesh daemon not yet running on this node, that's OK

    log.info("  ✓ %s (%s) — %d models, %dms", node["name"], ip, len(models), latency)
    return result


def merge_gossip(local_view: list, remote_view: list) -> list:
    """
    Merge two node lists. For each node, take the entry with the
    most recent last_seen timestamp (gossip: prefer fresher data).
    """
    merged = {n["name"]: n for n in local_view}
    for remote_node in remote_view:
        name = remote_node.get("name")
        if name not in merged:
            merged[name] = remote_node
        elif remote_node.get("last_seen", 0) > merged[name].get("last_seen", 0):
            merged[name] = remote_node
    return list(merged.values())


def discover_once(network_map: dict, local_hw: dict) -> dict:
    from mesh.state import save_state, elect_coordinator

    nodes = [n for n in network_map.get("nodes", []) if n.get("enabled", True)]
    log.info("Probing %d nodes (full mesh)...", len(nodes))

    # Inject local hw profile into our own node entry
    local_ip = local_hw.get("ip")  # may be absent; fine
    probed = []
    for node in nodes:
        result = probe_node(node)
        if local_ip and node["ip"] == local_ip:
            result.update({k: local_hw.get(k, result.get(k))
                           for k in ("inference_mb", "node_profile", "chipset")})
        probed.append(result)

    # Gossip: ask online nodes for their view, merge
    for node in [n for n in probed if n["status"] == "online"]:
        mesh_port = node.get("mesh_port", 11430)
        try:
            url = f"http://{node['ip']}:{mesh_port}/mesh/nodes"
            with urllib.request.urlopen(urllib.request.Request(url), timeout=2) as r:
                remote_nodes = json.loads(r.read())
            probed = merge_gossip(probed, remote_nodes)
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

    online_count = sum(1 for n in probed if n["status"] == "online")
    log.info("Mesh: %d/%d online. Coordinator: %s",
             online_count, len(probed),
             coordinator["name"] if coordinator else "NONE")
    return state


def daemon_loop(network_map: dict, local_hw: dict):
    log.info("Mesh discovery daemon starting. Interval: %ds", PROBE_INTERVAL)
    while True:
        try:
            discover_once(network_map, local_hw)
        except Exception as e:
            log.error("Discovery cycle error: %s", e)
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
