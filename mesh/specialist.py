"""
mesh/specialist.py — Specialization engine
Tracks task-type performance per node and suggests model swaps.
Copyright 2026 GrEEV.com KG

Updates specialization scores in the SQLite usage cache.
Emits model swap suggestions when confidence is high enough.
"""

import json
import logging
import sqlite3
import time
from pathlib import Path
from typing import Optional

log = logging.getLogger("mesh.specialist")

DB_PATH = Path(__file__).parent.parent / "data" / "usage_cache.db"

# Model swap suggestions: task_type → recommended model per profile
SPECIALIST_MODELS = {
    "code":      {"primary": "qwen2.5-coder:7b",   "secondary": "qwen2.5-coder:7b",
                  "qnap": "qwen2.5-coder:1.5b",    "windows-thin": "deepseek-coder:1.3b"},
    "anonymize": {"primary": "llama3.2:3b",         "secondary": "llama3.2:3b",
                  "qnap": "qwen2.5:1.5b",           "windows-thin": "qwen2.5:0.5b"},
    "summarize": {"primary": "qwen2.5:32b",         "secondary": "qwen2.5:7b",
                  "qnap": "qwen2.5:3b",             "windows-thin": "phi3.5-mini"},
    "translate": {"primary": "aya:8b",              "secondary": "aya:8b",
                  "qnap": "qwen2.5:1.5b",           "windows-thin": "qwen2.5:1.5b"},
    "classify":  {"primary": "qwen2.5:1.5b",        "secondary": "qwen2.5:1.5b",
                  "qnap": "qwen2.5:0.5b",           "windows-thin": "qwen2.5:0.5b"},
}

SUGGEST_THRESHOLD  = 0.75   # emit suggestion
AUTO_SWAP_THRESHOLD = 0.90  # auto-apply if node allows auto_specialize
MIN_SAMPLES = 20             # don't suggest until we have enough data


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS task_log (
            id          INTEGER PRIMARY KEY,
            ts          DATETIME DEFAULT CURRENT_TIMESTAMP,
            task_type   TEXT,
            routed_to   TEXT,
            model       TEXT,
            prompt_len  INTEGER,
            tokens_gen  INTEGER,
            duration_ms INTEGER,
            retried     BOOLEAN DEFAULT 0,
            quality     REAL
        );
        CREATE TABLE IF NOT EXISTS specialization_scores (
            node        TEXT,
            task_type   TEXT,
            score       REAL DEFAULT 0.5,
            sample_count INTEGER DEFAULT 0,
            updated_at  DATETIME,
            PRIMARY KEY (node, task_type)
        );
        CREATE TABLE IF NOT EXISTS model_suggestions (
            id          INTEGER PRIMARY KEY,
            ts          DATETIME DEFAULT CURRENT_TIMESTAMP,
            node        TEXT,
            from_model  TEXT,
            to_model    TEXT,
            task_type   TEXT,
            confidence  REAL,
            status      TEXT DEFAULT 'pending'
        );
    """)
    conn.commit()
    conn.close()


def record_task(task_type: str, routed_to: str, model: str,
               prompt_len: int, tokens_gen: int, duration_ms: int,
               retried: bool = False):
    """Record a completed task and update specialization scores."""
    # Quality signal: tokens/sec penalized for retries
    tps = tokens_gen / max(duration_ms / 1000, 0.001)
    quality = min(tps / 50, 1.0) * (0.5 if retried else 1.0)  # 50 t/s = perfect

    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute(
            "INSERT INTO task_log (task_type, routed_to, model, prompt_len, "
            "tokens_gen, duration_ms, retried, quality) VALUES (?,?,?,?,?,?,?,?)",
            (task_type, routed_to, model, prompt_len, tokens_gen, duration_ms,
             int(retried), quality)
        )

        # Update specialization score: EMA
        row = conn.execute(
            "SELECT score, sample_count FROM specialization_scores "
            "WHERE node=? AND task_type=?", (routed_to, task_type)
        ).fetchone()

        if row:
            old_score, count = row
            new_score = old_score * 0.95 + quality * 0.05
            count += 1
        else:
            new_score = quality
            count = 1

        conn.execute(
            "INSERT OR REPLACE INTO specialization_scores "
            "(node, task_type, score, sample_count, updated_at) VALUES (?,?,?,?,?)",
            (routed_to, task_type, new_score, count,
             time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        )
        conn.commit()
    finally:
        conn.close()

    _maybe_suggest(routed_to, task_type, model, new_score, count)


def _maybe_suggest(node: str, task_type: str, current_model: str,
                   score: float, sample_count: int):
    """Emit a model swap suggestion if thresholds are met."""
    if sample_count < MIN_SAMPLES:
        return
    if score < SUGGEST_THRESHOLD:
        return

    # Find suggested model for this node's profile
    # (We'd look up the profile from mesh-state.json in production)
    suggested = None
    for profile in ("primary", "secondary", "qnap", "windows-thin"):
        if profile in node.lower() or node in ("macbook-primary", "mac-mini"):
            suggested = SPECIALIST_MODELS.get(task_type, {}).get(profile)
            break
    if not suggested or suggested == current_model:
        return

    action = "auto" if score >= AUTO_SWAP_THRESHOLD else "suggest"
    conn = sqlite3.connect(DB_PATH)
    try:
        # Don't duplicate pending suggestions
        existing = conn.execute(
            "SELECT id FROM model_suggestions WHERE node=? AND task_type=? "
            "AND status='pending'", (node, task_type)
        ).fetchone()
        if existing:
            return
        conn.execute(
            "INSERT INTO model_suggestions "
            "(node, from_model, to_model, task_type, confidence, status) "
            "VALUES (?,?,?,?,?,?)",
            (node, current_model, suggested, task_type, score, action)
        )
        conn.commit()
        log.info("Suggestion [%s]: %s → load %s for %s (score=%.2f)",
                 action, node, suggested, task_type, score)
    finally:
        conn.close()


def get_pending_suggestions() -> list:
    """Return all pending model swap suggestions."""
    if not DB_PATH.exists():
        return []
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        "SELECT id, ts, node, from_model, to_model, task_type, confidence, status "
        "FROM model_suggestions WHERE status IN ('pending','auto') "
        "ORDER BY confidence DESC"
    ).fetchall()
    conn.close()
    keys = ("id","ts","node","from_model","to_model","task_type","confidence","status")
    return [dict(zip(keys, r)) for r in rows]


def get_specialization_scores(node: Optional[str] = None) -> list:
    """Return all specialization scores, optionally filtered by node."""
    if not DB_PATH.exists():
        return []
    conn = sqlite3.connect(DB_PATH)
    if node:
        rows = conn.execute(
            "SELECT node, task_type, score, sample_count, updated_at "
            "FROM specialization_scores WHERE node=? ORDER BY score DESC", (node,)
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT node, task_type, score, sample_count, updated_at "
            "FROM specialization_scores ORDER BY node, score DESC"
        ).fetchall()
    conn.close()
    keys = ("node", "task_type", "score", "sample_count", "updated_at")
    return [dict(zip(keys, r)) for r in rows]
