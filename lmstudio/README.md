# LM Studio — local-ai-stack integration

LM Studio exposes an **OpenAI-compatible REST API** on `http://localhost:1234/v1`.
These scripts let you discover local models, test the API, and connect any
OpenAI client to your Mac without copy-pasting.

---

## Quick start on macOS

### 1. Enable the local server in LM Studio

```
LM Studio → Developer tab (left sidebar) → Start Server
```

Default: `http://localhost:1234`

### 2. Discover models on disk

```zsh
bash ~/git/local-ai-stack/lmstudio/discover-models.sh
```

Scans `~/.lmstudio/models/` (and legacy paths) and prints every GGUF/safetensors
file with publisher, model name, and file size.

### 3. Test the live API

```zsh
bash ~/git/local-ai-stack/lmstudio/discover-models.sh --test
```

Sends a real chat request to the running server, lists all loaded models,
and prints the reply of the first one.

### 4. Point at another machine

```zsh
LMS_HOST=http://192.168.1.10:1234 \
  bash ~/git/local-ai-stack/lmstudio/discover-models.sh --test
```

> **Important:** LM Studio binds to `localhost` (127.0.0.1) by default.
> To accept LAN connections, go to:
> **LM Studio → Developer → Server → Network → change to `0.0.0.0`**
>
> For remote access without changing binding, use **LM Link** instead (see below).

---

## Models discovered on your Mac (2026-06-03)

The `--test` run showed these models loaded in LM Studio:

| Model | Notes |
|---|---|
| `openai/gpt-oss-120b` | Loaded first (used for test) |
| `qwen/qwen3-coder-next` | |
| `yoyo-v2-claude-4.6-mlx-gs32` | MLX (Apple Silicon native) |
| `google/gemma-3-27b` | |
| `google/gemma-3-12b` | |
| `openai-gpt-oss-36b-brainstorm20x-uncensored` | |
| `nousresearch/hermes-4-70b` | |
| `qwen/qwen3-next-80b` | |
| `text-embedding-nomic-embed-text-v1.5` | Embeddings |
| `openai/gpt-oss-20b` | |

---

## Python / OpenAI client

LM Studio is a drop-in replacement for the OpenAI API:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:1234/v1",
    api_key="lm-studio",          # any non-empty string
)

response = client.chat.completions.create(
    model="openai/gpt-oss-120b",  # use any model from the list above
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)
```

---

## LM Link — recommended for remote access

**LM Link** (introduced Feb 2026) lets you access models on any LM Studio machine
over an **end-to-end encrypted** connection without port forwarding or binding changes.
Powered by Tailscale.

### Setup

```
LM Studio → LM Link (sidebar) → Add Device
```

For headless Linux machines:

```bash
curl -fsSL https://lmstudio.ai/install.sh | bash
lms link enable
```

Once linked, remote models appear in your local LM Studio and are served
at `localhost:1234` — all existing scripts and tools work with zero changes.

Request access: https://link.lmstudio.ai

---

## Chat history backup

LM Studio stores all chat history as plain JSON files:

```
~/.lmstudio/conversations/          # v0.3+ (current)
~/Library/Application Support/LM-Studio/conversations/   # macOS legacy
```

### Backup

```zsh
cp -r ~/.lmstudio/conversations/ \
  ~/Backups/lmstudio-chats-$(date +%Y%m%d)/
```

### Restore on any Mac

```zsh
# After installing LM Studio on a new machine:
cp -r ~/Backups/lmstudio-chats-20260603/ ~/.lmstudio/conversations/
```

LM Studio reads the files on next launch — all chats reappear.
Files are not tied to an account or device.

### Sync to NAS continuously

```zsh
rsync -avz ~/.lmstudio/conversations/ \
  nas:/volume1/backups/lmstudio-chats/
```

---

## API endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/models` | GET | List loaded models |
| `/v1/chat/completions` | POST | Chat (streaming supported) |
| `/v1/completions` | POST | Raw text completion |
| `/v1/embeddings` | POST | Embeddings |

---

## Connecting to Perplexity from LM Studio

LM Studio itself cannot browse the web, but you can chain it:

```
User → LM Studio (local model) → [tool layer] → Perplexity Search API
```

See `lmstudio/perplexity-bridge/` (coming soon) for an MCP server that
gives LM Studio live web search via Perplexity API.
