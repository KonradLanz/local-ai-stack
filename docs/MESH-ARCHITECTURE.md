# Mesh Architecture — Adaptive Inference Network

**local-ai-stack** — Copyright 2026 GrEEV.com KG

This document describes the full target architecture for a self-organizing
local AI mesh where every node participates, tasks are distributed optimally,
usage patterns are cached, and nodes adaptively specialize over time.

---

## Design Principles

1. **Every node is a peer.** No single point of failure. PRIMARY is the
   *default coordinator* only — if it goes offline the mesh continues.
2. **Capability-aware routing.** Tasks are routed based on measured
   `inference_mb`, current load, and learned specialization scores.
3. **Adaptive specialization.** Nodes accumulate a task-type score vector.
   When a node is consistently better (speed × quality) at a task type,
   it is suggested to load a specialized model for that task.
4. **Local GUI on every node.** Each machine runs its own Open WebUI (or
   equivalent) that is mesh-aware: it submits to the scheduler, not to a
   fixed node.
5. **Privacy preserved.** The IPR filter runs on the originating node before
   any query leaves the LAN. Usage pattern cache is local-only.

---

## System Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 4: SPECIALIZATION ENGINE                                 │
│  mesh/specialist.py                                             │
│  • Tracks task-type → node performance scores                   │
│  • Suggests model swaps ("load anonymizer on qnap-nas")         │
│  • Overrides routing for specialized tasks automatically         │
│  • Learns from usage_cache.db (SQLite, local)                   │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 3: SCHEDULER                                             │
│  mesh/scheduler.py                                              │
│  • Accepts task requests from all nodes                         │
│  • Scores candidate nodes: inference_mb × load × specialization │
│  • Queues tasks when all candidates busy                        │
│  • Returns result or streams back to originating node           │
│  • Coordinator election: highest inference_mb online node wins  │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 2: MESH DISCOVERY                                        │
│  mesh/discovery.py  (replaces cluster/discover.py)              │
│  • Every node probes every other node (full mesh, not hub-spoke)│
│  • Gossip protocol: nodes share their view of the mesh          │
│  • Writes mesh-state.json (each node has its own copy)          │
│  • Nodes re-elect coordinator if current one goes offline       │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 1: NODE DAEMON                                           │
│  mesh/node.py                                                   │
│  • Runs on every machine                                        │
│  • Exposes: /mesh/status, /mesh/submit, /mesh/result            │
│  • Proxies to local Ollama OR forwards to scheduler             │
│  • Serves local GUI (Open WebUI) configured for this mesh node  │
│  • Reads hw-profile.json (from bootstrap-foundation detection)  │
├─────────────────────────────────────────────────────────────────┤
│  FOUNDATION (already built)                                     │
│  bootstrap-foundation/lib/detect-hardware.sh/.ps1               │
│  cluster/hw-profile.json  (per-node, gitignored)                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Coordinator Election

There is no hardcoded PRIMARY. The coordinator role floats to the
highest-`inference_mb` node that is currently online and reachable.

```
Every node on startup:
  1. Read own hw-profile.json → know own inference_mb
  2. Probe all nodes in network-map.yaml
  3. Sort online nodes by inference_mb DESC
  4. If self is #1 → become coordinator, start scheduler
  5. If self is not #1 → register with coordinator
  6. Watch coordinator heartbeat every 10s
  7. If coordinator disappears → re-run election
```

This means the MacBook is *usually* coordinator, but if it's closed/asleep
the Mac Mini takes over, and tasks keep flowing.

---

## Task Routing Score

For each incoming task, the scheduler computes a score for every online node:

```
score(node, task) =
    (inference_mb_available / task_estimated_tokens) × 0.40
  + (1 - current_load_fraction)                      × 0.30
  + specialization_score(node, task_type)             × 0.20
  + (1 / latency_ms)                                  × 0.10
```

- `inference_mb_available`: node's total minus currently running model sizes
- `task_estimated_tokens`: rough estimate from prompt length
- `specialization_score`: 0.0–1.0, learned from usage_cache
- `latency_ms`: last measured round-trip to that node

Highest score wins. Ties go to the node with most `inference_mb`.

---

## Task Types and Specializations

The scheduler classifies every incoming query into a task type using a
small local classifier (keyword + embedding heuristic, runs on any node).

| Task type | Key signals | Suggested specialist model |
|---|---|---|
| `code` | code block, function, class, debug, error trace | deepseek-coder:6.7b, qwen2.5-coder:7b |
| `anonymize` | PII, redact, GDPR, names + context | llama3.2:3b (fine-tuned) or prompt-engineered |
| `summarize` | long doc, tldr, summary, bullet points | qwen2.5:3b, mistral:7b |
| `translate` | language pair, translate to | aya:8b, qwen2.5:7b |
| `rag` | query that hits vector index | nomic-embed-text + llama3.1:8b |
| `chat` | conversational, open-ended | llama3.3:70b (PRIMARY), llama3.1:8b (secondary) |
| `classify` | category, label, sentiment | qwen2.5:1.5b (thin node sufficient) |
| `ipr-screen` | outbound query pre-screening | local tiny model (never leaves node) |

Specialization scores are updated after every completed task:
```
new_score = old_score × 0.95 + task_quality_signal × 0.05
```
Quality signal: tokens/sec × (1 if no retry, 0.5 if retried once).

---

## Adaptive Model Suggestion

When the specialization engine detects that a node is consistently
handling a task type with high scores, it emits a suggestion:

```json
{
  "node": "qnap-nas",
  "current_model": "qwen2.5:1.5b",
  "suggested_model": "qwen2.5-coder:1.5b",
  "task_type": "code",
  "reason": "68% of tasks on this node are code-type, score 0.82",
  "action": "suggest"  // or "auto" if confidence > 0.90 and node is non-primary
}
```

For `action: auto` (opt-in per node in network-map.yaml), the daemon
automatically runs `ollama pull` + `ollama rm` for the swap.
For `action: suggest`, it surfaces in the local GUI dashboard.

---

## Local GUI on Every Node

Each node runs Open WebUI pointed at the **local mesh node daemon**
(`http://localhost:11430/mesh`), not at a specific Ollama instance.
This means:

- User on QNAP web UI submits a query
- QNAP's node daemon receives it
- Scheduler (running on coordinator) scores all nodes
- Task goes to best available node (may be MacBook, may be QNAP itself)
- Result streams back through QNAP's node daemon to the user
- Usage recorded in local cache

The GUI also shows a **mesh dashboard** panel: live node status, current
load, specialization scores, and pending model swap suggestions.

---

## Usage Cache

SQLite database at `data/usage_cache.db` (local to each node, not synced).

```sql
CREATE TABLE task_log (
  id          INTEGER PRIMARY KEY,
  ts          DATETIME DEFAULT CURRENT_TIMESTAMP,
  task_type   TEXT,
  routed_to   TEXT,    -- node name
  model       TEXT,
  prompt_len  INTEGER,
  tokens_gen  INTEGER,
  duration_ms INTEGER,
  retried     BOOLEAN,
  quality     REAL     -- computed quality signal
);

CREATE TABLE specialization_scores (
  node        TEXT,
  task_type   TEXT,
  score       REAL,
  updated_at  DATETIME,
  PRIMARY KEY (node, task_type)
);

CREATE TABLE model_suggestions (
  id          INTEGER PRIMARY KEY,
  ts          DATETIME DEFAULT CURRENT_TIMESTAMP,
  node        TEXT,
  from_model  TEXT,
  to_model    TEXT,
  task_type   TEXT,
  confidence  REAL,
  status      TEXT  -- pending | accepted | rejected | auto-applied
);
```

---

## Implementation Phases

### Phase 1 (now → done): Foundation
- [x] bootstrap-foundation: detect-hardware.sh / .ps1
- [x] cluster: discover.py, proxy.py, install scripts
- [x] QNAP and Windows thin node setup

### Phase 2 (next): Mesh daemon + coordinator election
- [ ] mesh/node.py — per-node daemon, /mesh/* endpoints
- [ ] mesh/discovery.py — full-mesh gossip, coordinator election
- [ ] mesh/scheduler.py — score-based routing, queue
- [ ] mesh/state.py — mesh-state.json writer
- [ ] Update all install scripts to start mesh daemon

### Phase 3: Specialization engine
- [ ] mesh/classifier.py — task type detection (keyword + embedding)
- [ ] mesh/specialist.py — score tracking, suggestion engine
- [ ] data/usage_cache.db — SQLite schema + writer
- [ ] GUI dashboard panel — mesh status + suggestions

### Phase 4: Adaptive model management
- [ ] Auto model swap on high-confidence suggestions
- [ ] Per-node model inventory in mesh-state.json
- [ ] GUI: accept/reject suggestion with one click

---

## Network Map Extension

`cluster/network-map.yaml` gains two new per-node fields:

```yaml
nodes:
  - name: qnap-nas
    ip: "192.168.1.20"
    profile: qnap
    auto_specialize: false   # true = allow automatic model swaps
    specializations:         # seed hints (overridden by learned scores)
      - anonymize
      - classify
    enabled: true

  - name: macbook-primary
    ip: "192.168.1.10"
    profile: primary
    auto_specialize: false   # primary never auto-swaps — too risky
    enabled: true
```
