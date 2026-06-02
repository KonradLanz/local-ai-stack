# Architecture

## Repo Lineage

```
KonradLanz/ExecutionPolicy-Foundation   ← PowerShell policy bootstrap (Windows)
        │
KonradLanz/bootstrap-foundation         ← OS-aware shell/pkg bootstrap
        │                                  macOS, Ubuntu, Alpine, QNAP
        │
KonradLanz/local-ai-stack               ← THIS REPO
        │
        ├── KonradLanz/structured-pdf-pipeline  ← PDF extraction feeds RAG
        └── KonradLanz/dotfiles-macos            ← shell aliases for ollama/webui
```

---

## Cluster Network Topology

```
 pfsense router (192.168.1.1)
   │  DHCP reservations for all nodes
   │  (MAC → fixed IP, set in Services > DHCP > Static Mappings)
   │
   ├─── MacBook Pro M2 Max 96GB [PRIMARY]  192.168.1.10
   │       Ollama :11434  (LAN-visible, 0.0.0.0)
   │       Open WebUI :3000
   │       Cluster proxy :11430  ← all thin nodes point here
   │       Discovery daemon  (probes LAN every 30s)
   │       Models: llama3.3:70b, qwen2.5:32b, nomic-embed-text
   │
   ├─── Mac Mini M2/M4 [SECONDARY]          192.168.1.11
   │       Ollama :11434  (LAN-visible)
   │       Models: llama3.1:8b, qwen2.5:7b
   │       Fallback if PRIMARY offline
   │
   ├─── QNAP NAS 24GB [THIN: qnap]          192.168.1.20
   │       Ollama :11434  (localhost only, security)
   │       Open WebUI :3002  (NAS-local access)
   │       Tiny model: qwen2.5:1.5b (NAS tasks, IPR screening)
   │       ALL other inference → proxied to PRIMARY
   │
   ├─── Windows PC 1 [THIN: windows-thin]   192.168.1.30
   │       Ollama :11434  (localhost, GPU-accelerated)
   │       GPU model: phi3.5-mini or qwen2.5:1.5b-q4_K_M
   │       Specialty: code completion, offline editing
   │       ALL other inference → to PRIMARY via proxy
   │
   └─── Windows PC 2 [THIN: windows-thin]   192.168.1.31
           Same as PC 1
```

---

## Inference Routing Logic

```
Query arrives at cluster proxy (:11430)
  ↓
 parse model hint from request body
  ↓
  ├── tiny model request (1b, 1.5b, phi3.5-mini)
  │       → check thin nodes first (qnap, windows-thin)
  │       → if offline → fall back to PRIMARY
  │
  └── any other request
          → PRIMARY (highest-tier online node)
          → if PRIMARY offline → SECONDARY
          → if both offline → 503 error
```

Node availability is refreshed every 30 seconds by `cluster/discover.py`.
The proxy reads `cluster/live-nodes.json` (written by discover) and
serves the best node with sub-millisecond overhead.

---

## pfsense DHCP Reservation Setup

1. Log into pfsense: `http://192.168.1.1` (or your gateway IP)
2. **Services → DHCP Server → LAN**
3. Scroll to **DHCP Static Mappings** → **Add**
4. Enter: MAC address, IP address, hostname
5. Repeat for each node
6. **Diagnostics → Edit File**: optionally add DNS overrides so nodes
   resolve by hostname (`macbook-primary.local`, `qnap-nas.local`, etc.)
7. Update `cluster/network-map.yaml` with the reserved IPs

---

## Node Self-Selection

Each node runs its own installer from `cluster/`:

| Node type | Script | Profile auto-applied |
|---|---|---|
| MacBook Pro / Apple Silicon 64GB+ | `cluster/install-primary.sh` | `primary` |
| Mac Mini / Apple Silicon 16-32GB | `cluster/install-primary.sh` (sets `OLLAMA_MODEL=llama3.1:8b`) | `secondary` |
| QNAP NAS | `cluster/install-qnap.sh` | `qnap` |
| Windows 8-16GB + GPU | `cluster/install-windows-thin.ps1` | `windows-thin` |

Profiles and model recommendations are in `cluster/node-profiles.yaml`.

---

## IPR Filter in Cluster Context

```
Thin node (QNAP / Windows)
  │  user query → tiny local model for NAS/local tasks
  │
  └── if needs web search → perplexity_search()
          │  ipr_filter.screen_query()   ← runs on local node
          │  (tiny model can do local LLM classification)
          │
          ├── BLOCKED → log, return block message
          ├── REDACTED → sanitized query → Perplexity API
          └── CLEAN → original query → Perplexity API
```

The IPR filter runs **on the originating node** before anything leaves
the LAN. This means even thin nodes with tiny models perform privacy
screening locally before any outbound API call.

---

## Data Flow for PDFs

```
structured-pdf-pipeline output
  ↓
Open WebUI Knowledge Base (upload via UI or API)
  ↓
Vector + BM25 index (local, in Docker volume on PRIMARY)
  ↓
Model retrieves relevant chunks per query (RAG)
  ↓
Model answers — no external call needed for indexed PDFs
```

Thin nodes can access the PRIMARY's Open WebUI instance at
`http://192.168.1.10:3000` from any device on the LAN.
