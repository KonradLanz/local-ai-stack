# local-ai-stack

> Local-first AI agent stack for macOS, QNAP, Ubuntu, Alpine.  
> Your local models (LM Studio / Ollama GGUF) + web fetching + PDF RAG + Perplexity search bridge + IPR privacy filter.

[![License: AGPL-3.0-or-later OR MIT](https://img.shields.io/badge/License-AGPL--3.0--or--later%20OR%20MIT-blue.svg)](LICENSE)
[![Upstream: bootstrap-foundation](https://img.shields.io/badge/upstream-bootstrap--foundation-green)](https://github.com/KonradLanz/bootstrap-foundation)
[![Support: GrEEV.com KG](https://img.shields.io/badge/support-GrEEV.com%20KG-orange)](PROFESSIONAL-SUPPORT.md)

---

## What this is

A bootstrapper and tool collection that gives your local LLMs (running in
[LM Studio](https://lmstudio.ai) or [Ollama](https://ollama.com)) the ability to:

- 🌐 **Fetch websites** — extract clean Markdown from any URL
- 📄 **Read PDFs** — local extraction, feeds Open WebUI RAG
- 🔍 **Search via Perplexity** — optional API bridge, model decides when to use it
- 🔒 **IPR Privacy Filter** — screens outgoing queries to public AI for sensitive content
- 🐳 **One-command setup** — Docker Compose + shell bootstrap, OS-aware

Your GGUF model files are **never re-downloaded** — this stack points to
your existing `~/.lmstudio/models/` directory.

---

## Architecture

```
bash install.sh
       │
       ├── detects OS (macOS / Ubuntu / Alpine / QNAP)
       ├── installs Ollama (or connects to LM Studio)
       ├── imports existing GGUF models (zero re-download)
       ├── starts Open WebUI via Docker Compose
       └── registers tools:
               ├── tools/fetch_url.py          (web scraper)
               ├── tools/perplexity_search.py  (Perplexity API bridge)
               └── tools/ipr_filter.py         (outgoing query privacy guard)
```

The model **decides autonomously** which tools to invoke per query.
Perplexity is only called when the local model cannot answer from context.

---

## Quick Start

```bash
# macOS (requires Homebrew + Docker Desktop)
curl -fsSL https://raw.githubusercontent.com/KonradLanz/local-ai-stack/main/install.sh | bash

# Or clone first (recommended)
git clone https://github.com/KonradLanz/local-ai-stack.git
cd local-ai-stack
bash install.sh
```

Then open: http://localhost:3000

---

## Requirements

| Platform | Requirements |
|---|---|
| macOS | Homebrew, Docker Desktop, 8GB+ RAM |
| Ubuntu 22.04+ | Docker, curl, Python 3.10+ |
| QNAP QTS | Container Station (Docker), SSH access |
| Alpine | Docker, bash, Python 3 |

---

## Configuration

Copy `.env.example` to `.env` and fill in:

```bash
PERPLEXITY_API_KEY=pplx-...          # optional, enables Perplexity bridge
OLLAMA_MODEL=llama3.1:8b              # default model name in Ollama
LMSTUDIO_BASE_URL=http://host.docker.internal:1234/v1  # if using LM Studio
IPR_FILTER_ENABLED=true               # enable outgoing query screening
IPR_FILTER_MODEL=local                # use local model for screening
```

---

## IPR Privacy Filter

See [docs/IPR-POLICY.md](docs/IPR-POLICY.md) for the full policy framework.

The filter (`tools/ipr_filter.py`) intercepts queries **before** they leave
your machine to any public AI API (Perplexity, OpenAI, etc.) and:

1. Runs them through your **local model** for classification
2. Blocks or redacts queries matching configured sensitivity patterns
3. Logs blocked queries locally (never externally)
4. Returns a safe version of the query, or a local-only response

Pattern categories (configurable in `config/ipr_policy.yaml`):
- Personal identifiers (names, addresses, IDs)
- Internal project names / codenames
- Financial data patterns
- Legal / regulatory content
- Custom organization-specific patterns

---

## Tools

| Tool | File | Purpose |
|---|---|---|
| `fetch_url` | `tools/fetch_url.py` | Fetches any URL, returns clean Markdown |
| `perplexity_search` | `tools/perplexity_search.py` | Calls Perplexity Search API |
| `ipr_filter` | `tools/ipr_filter.py` | Screens outgoing queries for sensitive data |

All tools are Open WebUI–compatible Python functions with JSON schemas.
They also work standalone or in LangChain / n8n.

---

## Relationship to Other Repos

```
ExecutionPolicy-Foundation   ← PowerShell policy bootstrap (Windows)
       │
boostrap-foundation          ← OS-aware shell/package bootstrap (macOS/Linux)
       │
local-ai-stack               ← this repo
       │
       ├── structured-pdf-pipeline   ← PDF extraction output feeds RAG here
       └── dotfiles-macos            ← shell aliases for ollama/open-webui
```

---

## License

Dual licensed: **AGPL-3.0-or-later OR MIT** — see [LICENSE](LICENSE).

Dependency licenses are all compatible (MIT, BSD-3, Apache-2.0).  
See [LICENSE](LICENSE) for the full compatibility matrix.

For commercial licensing or professional support: office@greev.com  
See [COMMERCIAL-LICENSE-INQUIRY.md](COMMERCIAL-LICENSE-INQUIRY.md) and [PROFESSIONAL-SUPPORT.md](PROFESSIONAL-SUPPORT.md).

---

Copyright © 2026 GrEEV.com KG, Wien, Österreich
