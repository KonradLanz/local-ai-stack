# 🛤️ Catwalk

> Models don't always present their beauty on the same catwalk.
> Graz. Paris. London. Ollama. LM Studio. You name it.
>
> **Models laufen hier. Buchstäblich.**

Scripts and utilities to let your local model runners
share the same stage — and more importantly, the same model store.

---

## Scripts

| Script | What it does |
|---|---|
| [`link-ollama-models.sh`](./link-ollama-models.sh) | Symlinks Ollama GGUF blobs into LM Studio's model folder |

---

## link-ollama-models.sh

Creates symbolic links from Ollama's internal blob store into LM Studio's model directory.
No duplicate downloads. No extra dependencies beyond `awk`, `sed`, and `find`.

```sh
# Preview what would happen
./catwalk/link-ollama-models.sh --dry-run

# Create symlinks
./catwalk/link-ollama-models.sh

# Force-replace existing links
./catwalk/link-ollama-models.sh --force

# Verbose output
./catwalk/link-ollama-models.sh --verbose
```

### Paths

| Variable | Default |
|---|---|
| `OLLAMA_ROOT` | `~/.ollama/models` |
| `LMSTUDIO_ROOT` | `~/.cache/lm-studio/models/ollama` |

Override via environment:

```sh
OLLAMA_ROOT=/Volumes/external/.ollama/models ./catwalk/link-ollama-models.sh
```

### How it works

1. Scans all manifest files under `$OLLAMA_ROOT/manifests`
2. Extracts the blob digest for `application/vnd.ollama.image.model` layers
3. Maps the digest to a blob file under `$OLLAMA_ROOT/blobs`
4. Creates a `.gguf` symlink under `$LMSTUDIO_ROOT/<registry>/<namespace>/<model-tag>.gguf`

---

## Alternatives

- [Gollama](https://github.com/sammcj/gollama) — interactive TUI for Ollama model management, also handles LM Studio linking
- [lm-studio-ollama-bridge](https://github.com/ishan-marikar/lm-studio-ollama-bridge) — Go-based bidirectional sync utility
