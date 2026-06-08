# LM Studio / Ollama model sharing

This script exposes Ollama model blobs to LM Studio through symbolic links — no duplicate downloads, no extra dependencies.

## Why symlinks

- GGUF files are stored once in `~/.ollama/models/blobs`
- LM Studio reads them via a `.gguf` symlink in its own model tree
- No Go binary or third-party tool required
- macOS and Linux compatible (POSIX sh + awk/sed/find)

## Usage

```sh
# Default (dry-run to preview first)
./lmstudio/link-ollama-models.sh --dry-run

# Create symlinks
./lmstudio/link-ollama-models.sh

# Force-replace existing links
./lmstudio/link-ollama-models.sh --force

# Verbose output
./lmstudio/link-ollama-models.sh --verbose
```

## Paths

| Variable | Default |
|---|---|
| `OLLAMA_ROOT` | `~/.ollama/models` |
| `LMSTUDIO_ROOT` | `~/.cache/lm-studio/models/ollama` |

Both can be overridden via environment variables:

```sh
OLLAMA_ROOT=/Volumes/external/.ollama/models ./lmstudio/link-ollama-models.sh
```

## How it works

1. Scans all manifest files under `$OLLAMA_ROOT/manifests`
2. Extracts the blob digest for `application/vnd.ollama.image.model` layers
3. Maps the digest to a file under `$OLLAMA_ROOT/blobs`
4. Creates a `.gguf` symlink under `$LMSTUDIO_ROOT/<registry>/<namespace>/<model-tag>.gguf`

## Alternatives

- [Gollama](https://github.com/sammcj/gollama) — interactive TUI for Ollama model management, also handles LM Studio linking
- [lm-studio-ollama-bridge](https://github.com/ishan-marikar/lm-studio-ollama-bridge) — Go-based bidirectional sync utility
