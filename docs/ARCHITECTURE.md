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

## Runtime Architecture

```
┌─────────────────────────────────────────────────┐
│  YOUR MACHINE (everything inside is local)            │
│                                                       │
│  Open WebUI (Docker :3000)                            │
│    ├── Chat UI                                        │
│    ├── RAG / Document store (PDF, web pages)         │
│    └── Tool registry                                  │
│         ├── fetch_url()         ───────────┐       │
│         ├── ipr_filter()        (local only)   │       │
│         └── perplexity_search() ───────────┘       │
│              └─ calls ipr_filter first         │       │
│                                                       │
│  Ollama (:11434)           LM Studio (:1234)          │
│    └─ GGUF model files                               │
│       (~/.lmstudio/models/ or ~/.ollama/models/)      │
│                                                       │
└─────────────────────────────────────────────────┘
         │ only filtered queries leave
         ↓
  Perplexity Search API (external, optional)
```

## Tool Call Flow

1. User sends prompt to Open WebUI
2. Local model processes it — 100% local, no filtering needed
3. Model decides to call `perplexity_search(query)`
4. `perplexity_search` calls `ipr_filter.screen_query(query)`
   - BLOCK → blocked message returned to model, nothing sent externally
   - REDACT → sanitized query sent to Perplexity
   - ALLOW → original query sent to Perplexity
5. Perplexity results returned to model
6. Model synthesizes final answer using local context + search results

## Data Flow for PDFs

```
structured-pdf-pipeline output
  ↓
Open WebUI Knowledge Base (upload via UI or API)
  ↓
Vector + BM25 index (local, in Docker volume)
  ↓
Model retrieves relevant chunks per query (RAG)
  ↓
Model answers — no external call needed for indexed PDFs
```
