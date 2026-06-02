# Architecture

## Repository Dependency Chain

```
KonradLanz/ExecutionPolicy-Foundation   ← PowerShell policy bootstrap (Windows)
        │
KonradLanz/bootstrap-foundation         ← OS + HARDWARE detection (upstream)
        │   lib/detect-os.sh            ← $OS, $PKG_MGR
        │   lib/detect-hardware.sh      ← $HW_*, $HW_NODE_PROFILE
        │   lib/detect-hardware.ps1     ← $HW hashtable (Windows)
        │
KonradLanz/local-ai-stack               ← THIS REPO
        │   consumes detection — never duplicates it
        │
        ├── KonradLanz/structured-pdf-pipeline  ← PDF extraction feeds RAG
        └── KonradLanz/dotfiles-macos            ← shell aliases for ollama/webui
```

**Design rule:** OS and hardware detection live in bootstrap-foundation.
local-ai-stack sources those files, reads the exported variables,
and branches on them. No OS sniffing in local-ai-stack scripts.

---

## What bootstrap-foundation/lib/detect-hardware.sh provides

| Variable | Example value | Used for |
|---|---|---|
| `HW_RAM_MB` | 98304 | Node sizing decisions |
| `HW_UNIFIED_MB` | 98304 | Apple Silicon — same pool as RAM |
| `HW_VRAM_MB` | 2048 | Windows/Linux discrete GPU |
| `HW_INFERENCE_MB` | 78643 | Model size ceiling (80% of unified) |
| `HW_CPU_ARCH` | arm64 | Binary selection (Ollama ARM vs x86) |
| `HW_CHIPSET` | apple-silicon | Routing + install path |
| `HW_APPLE_CHIP` | m2 | Log output, model tuning |
| `HW_GPU_VENDOR` | apple | GPU backend selection |
| `HW_NODE_PROFILE` | primary | **Key: drives everything downstream** |

---

## Cluster Network Topology

```
 pfsense router
   │  DHCP static mappings (MAC → fixed IP)
   │
   ├─── MacBook Pro M2 Max 96GB [PRIMARY]  192.168.1.10
   │       HW_NODE_PROFILE=primary
   │       HW_INFERENCE_MB ≈ 78643MB
   │       Ollama :11434 (0.0.0.0 — LAN visible)
   │       Cluster proxy :11430
   │       Models: llama3.3:70b, qwen2.5:32b
   │
   ├─── Mac Mini M2/M4 [SECONDARY]          192.168.1.11
   │       HW_NODE_PROFILE=secondary
   │       Ollama :11434 (LAN visible)
   │       Models: llama3.1:8b
   │
   ├─── QNAP NAS 24GB [THIN: qnap]          192.168.1.20
   │       HW_NODE_PROFILE=qnap
   │       HW_INFERENCE_MB ≈ 8192MB
   │       Ollama :11434 (127.0.0.1 only)
   │       Model: qwen2.5:1.5b or 3b
   │
   ├─── Windows PC 1 [THIN]                 192.168.1.30
   │       HW_NODE_PROFILE=windows-thin
   │       HW_VRAM_MB=2048, HW_INFERENCE_MB=2048
   │       Ollama :11434 (127.0.0.1 only)
   │       Model: phi3.5-mini or qwen2.5:1.5b-q4
   │
   └─── Windows PC 2 [THIN]                 192.168.1.31
           same as PC 1
```

---

## hw-profile.json — the handshake artifact

Every install script writes `cluster/hw-profile.json` via `hw_json()` or
`HW-ToJson`. The discovery daemon (`cluster/discover.py`) reads this on
startup to know the local node's own capabilities without re-probing hardware.
The JSON is gitignored (generated, machine-specific).

Example for MacBook M2 Max 96GB:
```json
{
  "cpu_arch": "arm64",
  "chipset": "apple-silicon",
  "apple_chip": "m2",
  "ram_mb": 98304,
  "unified_mb": 98304,
  "vram_mb": 0,
  "inference_mb": 78643,
  "gpu_vendor": "apple",
  "node_profile": "primary",
  "profile_reason": "Apple Silicon m2, 98304MB unified — primary coordinator"
}
```

---

## Inference Routing Logic

```
Query → cluster proxy (:11430)
  ↓
  parse model hint
  ↓
  ├── tiny model (1b, 1.5b, phi3.5-mini keywords)
  │     → thin node (qnap/windows-thin) if online
  │     → fallback to PRIMARY
  │
  └── any other model
        → PRIMARY (highest HW_INFERENCE_MB online)
        → fallback: SECONDARY
        → 503 if all offline
```

Node capability is read from `cluster/live-nodes.json`,
which includes each node's `inference_mb` from their `hw-profile.json`.
This means routing decisions are hardware-aware, not just profile-name-aware.
