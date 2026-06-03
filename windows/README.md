# Windows Setup

Fuer PCs mit wenig VRAM (getestet: 8 GB RAM, 2 GB VRAM).

## Einmalig: Bootstrap

```powershell
# 1. PowerShell als normaler User oeffnen (kein Admin noetig)
# 2. Execution Policy pruefen/setzen:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 3. Ins Repo-Verzeichnis wechseln:
cd C:\Users\<dein-name>\git\local-ai-stack
# oder per git clone:
git clone https://github.com/KonradLanz/local-ai-stack.git
cd local-ai-stack

# 4. Bootstrap starten:
.\windows\install.ps1
```

Das Skript erledigt:
- Winget-Check
- Ollama installieren (OpenAI-kompatibler Server, Port 11434)
- Python 3.11 pruefen / installieren
- Modelle pullen: `qwen2.5:1.5b` + `phi4-mini`
- `LMS_HOST=http://localhost:11434` als Umgebungsvariable setzen

## Chatten

```powershell
# Modell-Picker erscheint automatisch:
.\windows\chat.ps1

# Direkt ein Modell angeben:
.\windows\chat.ps1 -Model qwen2.5
.\windows\chat.ps1 -Model phi4-mini

# Mit Perplexity Search (API-Key besorgen: https://www.perplexity.ai/settings/api):
$env:PERPLEXITY_API_KEY = 'pplx-xxx'
.\windows\chat.ps1 -Model qwen2.5

# Debug-Modus:
.\windows\chat.ps1 -Debug
```

## Empfohlene Modelle fuer 8 GB RAM / 2 GB VRAM

| Modell | RAM | Tool-Calling | Bemerkung |
|---|---|---|---|
| `qwen2.5:1.5b` | ~1.5 GB | sehr gut | **Empfehlung** |
| `phi4-mini` | ~2.5 GB | gut | Allrounder |
| `gemma3:1b` | ~1 GB | schwach | nur fuer Tests |
| `llama3.2:3b` | ~2.5 GB | gut | Alternative |

## Execution Policy — Kurzerklarung

Windows blockiert standardmassig fremde PowerShell-Skripte.
`RemoteSigned` bedeutet: lokale Skripte duerfen laufen,
heruntergeladene Skripte brauchen eine digitale Signatur.
Das ist der sichere Mittelweg fuer Entwickler.

```powershell
# Aktuellen Stand anzeigen:
Get-ExecutionPolicy -List

# Nur fuer den eigenen User setzen (kein Admin noetig):
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Updates

```powershell
git -C . pull
# Neue Modelle sind automatisch verfuegbar.
```
