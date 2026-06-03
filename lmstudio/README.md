# LM Studio — local-ai-stack integration

LM Studio exposes an **OpenAI-compatible REST API** on `http://localhost:1234/v1`.
These scripts let you discover local models, test the API, and connect any
OpenAI client to your Mac without copy-pasting.

---

## Quick start on macOS

### 1. Enable the local server in LM Studio

```
LM Studio → Developer tab (sidebar) → Start Server
```

Default: `http://localhost:1234`

### 2. Discover models on disk

```zsh
bash ~/git/local-ai-stack/lmstudio/discover-models.sh
```

This scans `~/.lmstudio/models/` (and legacy paths) and prints every GGUF
file with name and size.

### 3. Test the API

```zsh
bash ~/git/local-ai-stack/lmstudio/discover-models.sh --test
```

Sends a real chat request to the running server. Shows which model is loaded
and prints its reply.

### 4. Point at another machine

```zsh
LMS_HOST=http://192.168.1.62:1234 bash lmstudio/discover-models.sh --test
```

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
    model="lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)
```

---

## Chat history backup

LM Studio stores all chat history in:

```
~/.lmstudio/conversations/     # v0.3+
~/Library/Application Support/LM-Studio/conversations/   # macOS legacy
```

Each conversation is a plain **JSON file** (`<uuid>.json`).

### Backup

```zsh
cp -r ~/.lmstudio/conversations/ ~/Backups/lmstudio-chats-$(date +%Y%m%d)/
```

### Restore / migrate

Copy the JSON files back into the same directory on the new machine.
LM Studio reads them on next launch — all chats reappear.

```zsh
# On new machine, after installing LM Studio:
cp -r ~/Backups/lmstudio-chats-20260603/ ~/.lmstudio/conversations/
```

### rsync (keep in sync across machines)

```zsh
rsync -avz ~/.lmstudio/conversations/ nas:/volume1/backups/lmstudio-chats/
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

LM Studio itself can't browse the web, but you can chain it:

```
User → LM Studio (local model) → [your tool layer] → Perplexity Search API
```

See `lmstudio/perplexity-bridge/` (coming soon) for an MCP server that
gives LM Studio live web search via Perplexity API.
