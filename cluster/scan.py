"""
cluster/scan.py — Interactive network discovery wizard
Scans the local subnet, identifies nodes, asks confirmation,
then writes cluster/network-map.yaml.

Zero external dependencies (stdlib only).
Runs on macOS and Linux. Windows: use WSL or Git Bash.

Usage:
  python3 cluster/scan.py              # interactive wizard
  python3 cluster/scan.py --dry-run    # scan + print, don't write
  python3 cluster/scan.py --yes        # non-interactive, accept all detected nodes

Copyright 2026 GrEEV.com KG  |  AGPL-3.0-or-later
"""

import argparse
import concurrent.futures
import ipaddress
import json
import os
import platform
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT   = Path(__file__).parent.parent
MAP_OUT     = REPO_ROOT / "cluster" / "network-map.yaml"
MAP_BACKUP  = REPO_ROOT / "cluster" / "network-map.yaml.bak"

# ANSI colours (disabled on Windows cmd)
_TTY = sys.stdout.isatty() and platform.system() != "Windows"
def _c(code, s): return f"\033[{code}m{s}\033[0m" if _TTY else s
def green(s):  return _c("0;32", s)
def yellow(s): return _c("0;33", s)
def cyan(s):   return _c("0;36", s)
def bold(s):   return _c("1",    s)
def red(s):    return _c("0;31", s)
def dim(s):    return _c("2",    s)


# ---------------------------------------------------------------------------
# 1. Local network info
# ---------------------------------------------------------------------------

def local_interfaces() -> list[dict]:
    """Return list of {iface, ip, mac} for non-loopback interfaces."""
    results = []
    system = platform.system()

    if system == "Darwin":
        # ifconfig on macOS
        try:
            out = subprocess.check_output(["ifconfig"], text=True, stderr=subprocess.DEVNULL)
            iface = None
            for line in out.splitlines():
                m = re.match(r'^(\S+):', line)
                if m:
                    iface = m.group(1)
                m_ip = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', line)
                m_mac = re.search(r'ether ([0-9a-f:]{17})', line)
                if iface and m_ip:
                    ip = m_ip.group(1)
                    if not ip.startswith("127."):
                        results.append({"iface": iface, "ip": ip, "mac": ""})
                if iface and m_mac and results and results[-1]["iface"] == iface:
                    results[-1]["mac"] = m_mac.group(1)
        except Exception:
            pass

    elif system == "Linux":
        try:
            out = subprocess.check_output(["ip", "-4", "addr", "show"], text=True)
            iface = None
            for line in out.splitlines():
                m = re.match(r'^\d+: (\S+):', line)
                if m:
                    iface = m.group(1)
                m_ip = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', line)
                if iface and m_ip:
                    ip = m_ip.group(1)
                    if not ip.startswith("127."):
                        results.append({"iface": iface, "ip": ip, "mac": ""})
        except Exception:
            pass

    # De-dup by IP, prefer en0/eth0
    seen = set()
    deduped = []
    for r in sorted(results, key=lambda x: (0 if x["iface"] in ("en0","eth0") else 1)):
        if r["ip"] not in seen:
            seen.add(r["ip"])
            deduped.append(r)
    return deduped


def subnet_from_ip(ip: str) -> str:
    """Guess /24 subnet from IP (e.g. 192.168.1.62 -> 192.168.1.0/24)."""
    parts = ip.split(".")
    return f"{parts[0]}.{parts[1]}.{parts[2]}.0/24"


# ---------------------------------------------------------------------------
# 2. ARP table (instant, no packets sent)
# ---------------------------------------------------------------------------

def read_arp_table() -> dict[str, dict]:
    """Parse arp -a output. Returns {ip: {hostname, mac, iface}}."""
    table = {}
    try:
        out = subprocess.check_output(["arp", "-a"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return table

    for line in out.splitlines():
        # hostname (ip) at mac on iface [type]
        # ? (192.168.1.201) at 24:5e:be:4f:d0:cd on en0 ifscope [ethernet]
        m = re.match(
            r'(\S+)\s+\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-f:]+|\(incomplete\))'
            r'(?:\s+on\s+(\S+))?',
            line
        )
        if not m:
            continue
        hostname_raw, ip, mac, iface = m.groups()
        if mac == "(incomplete)" or ip.endswith(".255") or ip.startswith("224."):
            continue
        table[ip] = {
            "hostname": hostname_raw if hostname_raw != "?" else "",
            "mac":      mac,
            "iface":    iface or "",
        }
    return table


# ---------------------------------------------------------------------------
# 3. Ping sweep (parallel, 200ms timeout)
# ---------------------------------------------------------------------------

def _ping_one(ip: str) -> bool:
    system = platform.system()
    flag   = "-c" if system != "Windows" else "-n"
    w_flag = ["-W", "200"] if system == "Darwin" else ["-w", "200"] if system == "Linux" else ["/w", "200"]
    try:
        r = subprocess.run(
            ["ping", flag, "1"] + w_flag + [ip],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1
        )
        return r.returncode == 0
    except Exception:
        return False


def ping_sweep(subnet: str, max_workers: int = 64) -> set[str]:
    """Ping all hosts in /24 subnet. Returns set of live IPs."""
    network = ipaddress.ip_network(subnet, strict=False)
    hosts   = [str(h) for h in network.hosts()]
    live    = set()
    print(f"  Pinging {len(hosts)} hosts", end="", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
        futures = {ex.submit(_ping_one, ip): ip for ip in hosts}
        done = 0
        for f in concurrent.futures.as_completed(futures):
            ip = futures[f]
            if f.result():
                live.add(ip)
            done += 1
            if done % 32 == 0:
                print(".", end="", flush=True)
    print(f" {len(live)} alive")
    return live


# ---------------------------------------------------------------------------
# 4. Service probes
# ---------------------------------------------------------------------------

def probe_port(ip: str, port: int, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def probe_ollama(ip: str, port: int = 11434) -> dict | None:
    """Returns {models: [...]} if Ollama is running, else None."""
    try:
        with urllib.request.urlopen(
            urllib.request.Request(f"http://{ip}:{port}/api/tags"), timeout=2
        ) as r:
            data = json.loads(r.read())
        return {"models": [m["name"] for m in data.get("models", [])]}
    except Exception:
        return None


def probe_ssh(ip: str) -> bool:
    return probe_port(ip, 22)


def probe_rdp(ip: str) -> bool:
    return probe_port(ip, 3389)


def probe_smb(ip: str) -> bool:
    return probe_port(ip, 445)


def reverse_dns(ip: str) -> str:
    try:
        return socket.gethostbyaddr(ip)[0]
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# 5. OS / node type heuristics
# ---------------------------------------------------------------------------

QNAP_MAC_PREFIXES = (
    "00:08:9b", "24:5e:be", "00:50:43",  # QNAP
)

def guess_profile(ip: str, hostname: str, mac: str,
                 has_ssh: bool, has_rdp: bool, has_smb: bool,
                 ollama: dict | None, is_self: bool) -> str:
    if is_self:
        return "primary"
    mac_lower = mac.lower()
    if any(mac_lower.startswith(p) for p in QNAP_MAC_PREFIXES):
        return "qnap"
    h = hostname.lower()
    if "nas" in h or "qnap" in h or "synology" in h:
        return "qnap"
    if has_rdp and not has_ssh:
        return "windows-thin"
    if has_rdp and has_smb:
        return "windows-thin"
    if has_ssh:
        return "secondary"
    return "unknown"


# ---------------------------------------------------------------------------
# 6. Full scan
# ---------------------------------------------------------------------------

def scan(subnet: str, self_ip: str, do_sweep: bool = True) -> list[dict]:
    print()
    print(bold("[1/3] Reading ARP table..."))
    arp = read_arp_table()
    print(f"  {len(arp)} entries in ARP cache")

    live_ips: set[str] = set(arp.keys())

    if do_sweep:
        print(bold("[2/3] Ping sweep..."))
        live_ips |= ping_sweep(subnet)
    else:
        print(bold("[2/3] Skipping ping sweep (--no-sweep)"))

    print(bold("[3/3] Probing services on live hosts..."))
    nodes = []
    for ip in sorted(live_ips, key=lambda x: list(map(int, x.split(".")))):
        arp_info  = arp.get(ip, {})
        mac       = arp_info.get("mac", "")
        hostname  = arp_info.get("hostname", "") or reverse_dns(ip)
        # strip domain suffix for display
        short_host = hostname.split(".")[0] if hostname else ""

        is_self = (ip == self_ip)

        has_ssh = probe_ssh(ip)
        has_rdp = probe_rdp(ip)
        has_smb = probe_smb(ip)
        ollama  = probe_ollama(ip)

        profile = guess_profile(ip, short_host, mac, has_ssh, has_rdp, has_smb, ollama, is_self)

        services = []
        if is_self:   services.append("self")
        if has_ssh:   services.append("ssh")
        if has_rdp:   services.append("rdp")
        if has_smb:   services.append("smb")
        if ollama:    services.append(f"ollama({len(ollama['models'])} models)")

        nodes.append({
            "ip":        ip,
            "hostname":  short_host,
            "fqdn":      hostname,
            "mac":       mac,
            "profile":   profile,
            "services":  services,
            "ollama":    ollama,
            "has_ssh":   has_ssh,
            "has_rdp":   has_rdp,
            "is_self":   is_self,
        })

        status = cyan(f"{ip:17}") + f"  {short_host or dim('(no name)'):25}"
        svc    = "  " + " ".join(green(s) if "ollama" in s else yellow(s) for s in services)
        prof   = dim(f"  [{profile}]")
        print(f"  {status}{svc}{prof}")

    return nodes


# ---------------------------------------------------------------------------
# 7. Interactive confirmation + naming
# ---------------------------------------------------------------------------

def ask(prompt: str, default: str = "") -> str:
    hint = f" [{default}]" if default else ""
    try:
        val = input(f"  {prompt}{hint}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)
    return val or default


def confirm(prompt: str, default: bool = True) -> bool:
    hint = "Y/n" if default else "y/N"
    try:
        val = input(f"  {prompt} [{hint}]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)
    if not val:
        return default
    return val.startswith("y")


def interactive_select(nodes: list[dict], auto: bool = False) -> list[dict]:
    """
    Walk each discovered node, ask user to include/exclude,
    optionally rename, set profile.
    Returns the accepted node list.
    """
    PROFILES = ["primary", "secondary", "qnap", "windows-thin", "micro"]
    accepted = []

    print()
    print(bold("=== Node confirmation ==="))
    print(dim("  For each node: confirm inclusion, name, and profile."))
    print()

    for node in nodes:
        ip      = node["ip"]
        host    = node["hostname"] or ip
        profile = node["profile"]
        svcs    = node["services"]

        print(bold(f"  {ip}") + f"  {cyan(host)}  {dim(str(svcs))}")

        if auto:
            include = profile != "unknown"
        else:
            include = confirm(f"Include this node in network-map?", default=(profile != "unknown"))

        if not include:
            print(dim("    skipped"))
            print()
            continue

        if not auto:
            name    = ask("  Name (slug, no spaces)", default=host or ip.replace(".","-"))
            profile = ask(f"  Profile {PROFILES}", default=profile)
        else:
            name = host or ip.replace(".", "-")

        accepted.append({**node, "name": name, "profile": profile})

        # Access suggestions
        print_access_hints(node)
        print()

    return accepted


def print_access_hints(node: dict):
    ip      = node["ip"]
    host    = node["hostname"] or ip
    profile = node["profile"]

    hints = []

    if node.get("has_ssh"):
        hints.append(("SSH",  green(f"ssh {host or ip}")))

    if node.get("has_rdp"):
        # Windows has OpenSSH since Win10 1809, but RDP is more common
        hints.append(("RDP",  yellow(f"open rdp://{ip}  (or: mstsc /v:{ip}"))  + ")"))
        # Windows SSH (if port 22 also open)
        if node.get("has_ssh"):
            hints.append(("Win SSH", green(f"ssh {host or ip}  # OpenSSH for Windows")))
        # PowerShell remoting via WinRM (not probed but worth noting)
        hints.append(("PSRemote", dim(f"Enter-PSSession -ComputerName {ip}  # if WinRM enabled")))

    if node.get("ollama"):
        models = node["ollama"].get("models", [])
        hints.append(("Ollama", cyan(f"curl http://{ip}:11434/api/tags")))
        if models:
            hints.append(("Models", dim(", ".join(models[:5]) + (" ..." if len(models) > 5 else ""))))

    if profile == "qnap":
        hints.append(("QNAP web", cyan(f"open http://{ip}:8080")))
        hints.append(("QNAP SSH", green(f"ssh admin@{ip}")))

    if hints:
        print(dim("    Access:"))
        for label, cmd in hints:
            print(f"    {label:12} {cmd}")


# ---------------------------------------------------------------------------
# 8. Write network-map.yaml
# ---------------------------------------------------------------------------

def write_network_map(nodes: list[dict], subnet: str, gateway: str,
                     cluster_name: str, dry_run: bool = False):
    lines = [
        f"# network-map.yaml — generated by cluster/scan.py on {time.strftime('%Y-%m-%d %H:%M')}",
        f"# Edit freely. Re-run scan.py to refresh.",
        "",
        f'cluster_name: "{cluster_name}"',
        f'subnet: "{subnet}"',
        f'gateway: "{gateway}"',
        "",
        "nodes:",
    ]

    for i, n in enumerate(nodes):
        ollama_port = 11434
        webui_port  = 3000 + i
        enabled     = n["profile"] not in ("unknown",)

        lines += [
            f"  - name: {n['name']}",
            f"    profile: {n['profile']}",
            f"    hostname: {n['hostname'] or n['name']}",
            f"    ip: \"{n['ip']}\"",
            f"    mac: \"{n['mac']}\"",
            f"    ollama_port: {ollama_port}",
            f"    mesh_port: 11430",
            f"    openwebui_port: {webui_port}",
            f"    enabled: {'true' if enabled else 'false'}",
        ]
        if n.get("has_ssh"):
            lines.append(f"    # ssh: ssh {n['hostname'] or n['ip']}")
        if n.get("has_rdp"):
            lines.append(f"    # rdp: mstsc /v:{n['ip']}  or  open rdp://{n['ip']}")
        lines.append("")

    yaml_text = "\n".join(lines)

    if dry_run:
        print()
        print(bold("--- network-map.yaml (dry run) ---"))
        print(yaml_text)
        print(bold("--- end ---"))
        return

    # Backup existing
    if MAP_OUT.exists():
        MAP_OUT.rename(MAP_BACKUP)
        print(f"  Backed up existing map → {MAP_BACKUP.name}")

    MAP_OUT.write_text(yaml_text)
    print(green(f"  Written: {MAP_OUT}"))


# ---------------------------------------------------------------------------
# 9. Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Scan LAN and build cluster/network-map.yaml"
    )
    parser.add_argument("--dry-run",   action="store_true",
                        help="Print result, don't write file")
    parser.add_argument("--yes",  "-y", action="store_true",
                        help="Non-interactive: accept all detected nodes")
    parser.add_argument("--no-sweep",  action="store_true",
                        help="Skip ping sweep, use ARP cache only (faster)")
    parser.add_argument("--subnet",    default="",
                        help="Override subnet (default: auto-detect from en0)")
    parser.add_argument("--cluster",   default="greev-home-lab",
                        help="Cluster name to write into YAML")
    args = parser.parse_args()

    print()
    print(bold("================================================"))
    print(bold("  local-ai-stack: Network Discovery Wizard"))
    print(bold("================================================"))

    # Detect own IP
    ifaces = local_interfaces()
    if not ifaces:
        print(red("  Could not detect local IP. Are you on a network?"))
        sys.exit(1)

    print()
    print("  Local interfaces:")
    for ifc in ifaces:
        print(f"    {ifc['iface']:8} {cyan(ifc['ip'])}  {dim(ifc['mac'])}")

    # Pick primary interface (en0 / eth0 preferred)
    primary = ifaces[0]
    self_ip = primary["ip"]

    subnet = args.subnet or subnet_from_ip(self_ip)
    print(f"  Scanning subnet : {cyan(subnet)}")
    print(f"  This machine    : {cyan(self_ip)}")

    # Scan
    nodes = scan(subnet, self_ip, do_sweep=not args.no_sweep)

    if not nodes:
        print(red("  No live hosts found."))
        sys.exit(1)

    # Confirm / name nodes
    accepted = interactive_select(nodes, auto=args.yes)

    if not accepted:
        print(yellow("  No nodes selected. Nothing written."))
        sys.exit(0)

    # Guess gateway: first non-self IP in subnet (usually .1 or .2)
    live_ips = sorted([n["ip"] for n in nodes],
                      key=lambda x: list(map(int, x.split("."))))
    gateway = next((ip for ip in live_ips if ip != self_ip), live_ips[0])

    # Summary
    print()
    print(bold(f"  Accepted {len(accepted)} node(s):"))
    for n in accepted:
        status = green("✓") if n["profile"] != "unknown" else yellow("-")
        print(f"    {status} {n['ip']:17} {n['name']:25} [{n['profile']}]")

    # Write
    print()
    if not args.dry_run and not args.yes:
        if not confirm(f"Write to {MAP_OUT.relative_to(REPO_ROOT)}?", default=True):
            print(dim("  Aborted."))
            sys.exit(0)

    write_network_map(
        nodes        = accepted,
        subnet       = subnet,
        gateway      = gateway,
        cluster_name = args.cluster,
        dry_run      = args.dry_run,
    )

    if not args.dry_run:
        print()
        print(bold("  Next steps:"))
        print(f"    git pull && git diff cluster/network-map.yaml")
        print(f"    .venv/bin/python cluster/discover.py --once")
        print()


if __name__ == "__main__":
    main()
