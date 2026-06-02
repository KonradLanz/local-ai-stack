# pfsense DHCP Setup for local-ai-stack Cluster

**local-ai-stack** — Copyright 2026 GrEEV.com KG

This guide walks through setting static DHCP leases in pfsense for each
cluster node so their IPs never change, even after reboots or DHCP renewal.

---

## 1. Find Each Node's MAC Address

### macOS (MacBook, Mac Mini)
```bash
# WiFi MAC
ifconfig en0 | grep ether

# Ethernet MAC
ifconfig en1 | grep ether

# Or: System Settings → General → About → hold Option to see MAC
```
Use **Ethernet MAC** if the node is wired (preferred for a server).

### QNAP
```
Control Panel → Network & File Services → Network & Virtual Switch
→ Interfaces → click the interface → Properties
```
Or via SSH:
```bash
cat /sys/class/net/eth0/address
```

### Windows
```powershell
ipconfig /all
# Look for: Physical Address . . . : XX-XX-XX-XX-XX-XX
# for the adapter actually connected to your LAN
```

---

## 2. Create Static Mappings in pfsense

1. Log in to pfsense at `http://192.168.1.1` (or your LAN gateway)
2. Navigate to **Services → DHCP Server → LAN** (or your LAN interface)
3. Scroll down to **DHCP Static Mappings for this Interface**
4. Click **+ Add** for each node:

| Field | Value |
|---|---|
| MAC address | the MAC from step 1 (lowercase, colon-separated) |
| IP address | your chosen reserved IP |
| Hostname | short hostname (e.g. `macbook-primary`) |
| Description | optional note |

5. Click **Save**, then **Apply Changes** at the top

**Suggested IP assignments:**

```
192.168.1.10  macbook-primary    (PRIMARY: MacBook Pro M2 Max)
192.168.1.11  mac-mini           (SECONDARY: Mac Mini, if present)
192.168.1.20  qnap-nas           (THIN: QNAP NAS)
192.168.1.30  windows-pc-1       (THIN: Windows PC 1)
192.168.1.31  windows-pc-2       (THIN: Windows PC 2)
```

Adjust the subnet to match yours (e.g. `10.0.0.x` or `172.16.x.x`).

---

## 3. Apply New IP on Each Node

After adding static mappings, force each node to renew:

### macOS
```bash
# Release and renew via Wi-Fi
sudo ipconfig set en0 DHCP

# Or toggle Wi-Fi off/on in System Settings
```

### QNAP
```bash
# via SSH
udhcpc -i eth0
# Or: Control Panel → Network → Interfaces → Manage → Reconnect
```

### Windows
```powershell
ipconfig /release
ipconfig /renew
```

---

## 4. Update network-map.yaml

Edit `cluster/network-map.yaml` on your PRIMARY node with the confirmed IPs:

```yaml
nodes:
  - name: macbook-primary
    ip: "192.168.1.10"    # confirmed from pfsense
    mac: "a0:b1:c2:d3:e4:f5"  # fill in
    enabled: true
  # ... etc
```

Then run the discovery daemon to verify all nodes are reachable:

```bash
python3 cluster/discover.py --once
```

---

## 5. Optional: DNS Hostnames

For name-based access (`http://macbook-primary:3000`) instead of IPs:

1. pfsense: **Services → DNS Resolver → Host Overrides**
2. Add an override for each node:
   - Host: `macbook-primary`
   - Domain: your domain or `local`
   - IP: `192.168.1.10`
3. Ensure **DNS Resolver** is enabled and clients use pfsense as DNS

---

## 6. Firewall Consideration

If pfsense has inter-VLAN rules, ensure the thin nodes can reach
`192.168.1.10:11434` (Ollama on PRIMARY) and `192.168.1.10:3000`
(Open WebUI) over your LAN.

For a flat home network with no VLANs, no firewall rules are needed.
