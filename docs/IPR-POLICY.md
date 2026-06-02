# IPR Privacy Policy Framework

**local-ai-stack** — Copyright 2026 GrEEV.com KG

---

## Purpose

This document describes the Information Privacy & Rights (IPR) policy
framework built into `local-ai-stack`. Its goal is to prevent accidental
disclosure of sensitive, confidential, or personal data when the local
AI agent decides to route a query to an external public AI API
(such as Perplexity Search).

---

## Threat Model

The primary risk: a user's prompt contains sensitive content, the model
decides to use the `perplexity_search` tool, and the sensitive content
is sent verbatim to a third-party API outside the user's control.

Examples:
- User pastes an email with a name and email address and asks the model
  to "search for more info about this person"
- User includes internal project names or contract numbers in context
- User accidentally includes credentials (API keys, passwords) in a query

---

## Architecture of Protection

```
User query
    ↓
Local model (Ollama / LM Studio) — always local, never filtered
    ↓  (model decides to use perplexity_search)
perplexity_search() calls → screen_query() in ipr_filter.py
    ↓
  [BLOCK]  → log locally, return block message to model
  [REDACT] → send sanitized version to Perplexity API
  [ALLOW]  → send original query to Perplexity API
    ↓
Perplexity API response → back to local model → user
```

The local model itself is **never filtered** — all your data stays local.
Only outgoing calls to external APIs are screened.

---

## Configuration

Edit `config/ipr_policy.yaml` to customize:

- **sensitivity**: `low` / `medium` / `high`
- **block_patterns**: regex patterns that cause a hard block
- **redact_patterns**: regex patterns whose matches are replaced with `[REDACTED]`
- **use_local_llm_for_borderline**: enable local LLM classification for ambiguous queries
- **custom_block_patterns**: add your organization-specific patterns

---

## GDPR Relevance (Austria / EU)

Under GDPR (Verordnung (EU) 2016/679), sending personal data of EU residents
to third-party AI services constitutes a data transfer that requires:

- A lawful basis (Art. 6)
- A Data Processing Agreement (DPA) with the third party if they process
  data on your behalf (Art. 28)
- For transfers outside the EU/EEA: appropriate safeguards (Art. 46)

The IPR filter provides a **technical safeguard** to reduce the likelihood
of personal data leaving your environment. It does NOT replace:
- A GDPR-compliant data processing policy
- DPAs with Perplexity AI or other external providers
- Legal review of your specific use case

For Austrian legal context: WKO and RTR provide guidance on AI and data
protection. Consult legal counsel for compliance questions.

---

## What the Filter Does NOT Protect Against

- Content already in Perplexity's indexed web (it's public)
- Queries that contain sensitive data not matching configured patterns
- Data sent directly by the user via Open WebUI's non-tool interfaces
- Models that bypass tools and use built-in web access (disable those in Open WebUI settings)

---

## Extending the Filter

To add custom patterns for your organization:

```yaml
# config/ipr_policy.yaml
custom_block_patterns:
  - 'Project\s+Phoenix'      # internal codename
  - 'Kunde\s+Nummer\s+\d+'   # customer number pattern
  - '\bNDA\b.*details'        # NDA references
```

To enable local LLM classification for borderline cases:

```yaml
use_local_llm_for_borderline: true
```

This adds ~1-2 seconds per filtered query. The local model is asked to
classify whether the query contains sensitive data. It never leaves your
machine.

---

## Audit Log

Blocked queries are logged to `data/ipr_blocked.log` (covered by `.gitignore`).
The log contains: timestamp, matched pattern, first 200 chars of the query.
This file never leaves your machine automatically.

To review:
```bash
cat data/ipr_blocked.log
```

To disable logging:
```yaml
# config/ipr_policy.yaml
log_blocked: false
```
