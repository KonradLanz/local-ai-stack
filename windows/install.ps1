# =============================================================================
# windows/install.ps1
# Bootstrap fuer Windows-PCs mit wenig VRAM (getestet: 8 GB RAM, 2 GB VRAM)
# Kompatibel mit PowerShell 5.1+ (Windows vorinstalliert) UND PS 7+
#
# Ausfuehren (einmalig):
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#   .\windows\install.ps1
#
# License: AGPL-3.0-or-later OR MIT  Copyright 2026 GrEEV.com KG
# =============================================================================
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "   OK  $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "   WARN  $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "   FAIL  $msg" -ForegroundColor Red }

# ---- Execution Policy pruefen ----
Write-Step "Execution Policy pruefen"
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Restricted') {
    Write-Warn "Execution Policy ist Restricted."
    $answer = Read-Host "   Jetzt auf RemoteSigned setzen? [j/N]"
    if ($answer -match '^[jJyY]') {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        Write-Ok "ExecutionPolicy = RemoteSigned"
    } else {
        Write-Fail "Abbruch."
        Write-Host "   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
        exit 1
    }
} else {
    Write-Ok "ExecutionPolicy = $policy"
}

# ---- Winget pruefen ----
Write-Step "Winget pruefen"
try {
    $wgver = (winget --version 2>$null)
    Write-Ok "winget $wgver"
} catch {
    Write-Warn "winget nicht gefunden — https://aka.ms/getwinget"
}

# ---- Ollama installieren ----
Write-Step "Ollama pruefen / installieren"
# PS5.1-kompatibel: kein ?. Operator
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    $ollamaVer = (ollama --version 2>$null)
    Write-Ok "Ollama bereits installiert: $ollamaVer"
} else {
    Write-Host "   Ollama nicht gefunden. Installiere via winget..."
    try {
        winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements
        Write-Ok "Ollama installiert."
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH','User')
    } catch {
        Write-Warn "winget fehlgeschlagen."
        Write-Host "   Manuell: https://ollama.com/download/OllamaSetup.exe"
        Write-Host "   Danach dieses Skript erneut ausfuehren."
        exit 1
    }
}

# ---- Python pruefen ----
Write-Step "Python pruefen"
$py = $null
foreach ($cmd in @('python','python3','py')) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match '3\.(1[0-9]|[89])') {
            $py = $cmd
            Write-Ok "$cmd => $ver"
            break
        }
    } catch { }
}
if (-not $py) {
    Write-Warn "Python 3.8+ nicht gefunden."
    try {
        winget install -e --id Python.Python.3.11 --silent --accept-package-agreements --accept-source-agreements
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH','User')
        $py = 'python'
        Write-Ok "Python 3.11 installiert."
    } catch {
        Write-Fail "Python-Install fehlgeschlagen. Manuell: https://python.org"
        exit 1
    }
}

# ---- Repo-Pfad ----
$repoRoot = Split-Path $PSScriptRoot -Parent
Write-Ok "Repo-Root: $repoRoot"

# ---- Ollama-Server starten ----
Write-Step "Ollama-Server starten (falls noetig)"
try {
    $null = Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 3
    Write-Ok "Ollama-Server laeuft bereits."
} catch {
    Write-Host "   Starte Ollama im Hintergrund..."
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Write-Ok "Ollama gestartet."
}

# ---- Modelle pullen ----
Write-Step "Empfohlene Modelle fuer 8 GB RAM / 2 GB VRAM pullen"

$models = @(
    @{ name = 'qwen2.5:1.5b'; reason = 'Bestes Tool-Calling in <2 GB RAM' },
    @{ name = 'phi4-mini';     reason = 'Guter Allrounder, ~2.5 GB RAM'   }
)

foreach ($m in $models) {
    Write-Host "   Pulling $($m.name)  ($($m.reason))..."
    try {
        ollama pull $m.name
        Write-Ok $m.name
    } catch {
        Write-Warn "Konnte $($m.name) nicht pullen: $_"
    }
}

# ---- LMS_HOST setzen ----
Write-Step "LMS_HOST Umgebungsvariable setzen (User-scope)"
[System.Environment]::SetEnvironmentVariable('LMS_HOST', 'http://localhost:11434', 'User')
$env:LMS_HOST = 'http://localhost:11434'
Write-Ok "LMS_HOST=http://localhost:11434"

# ---- Abschluss ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host "================================================================"
Write-Host ""
Write-Host "  Naechste Schritte:"
Write-Host ""
Write-Host "  1. Neues PowerShell-Fenster oeffnen (LMS_HOST wirkt erst dann)"
Write-Host ""
Write-Host "  2. Chat starten:"
Write-Host "     .\windows\chat.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Oder direkt:"
Write-Host "     python lmstudio\chat_with_tools.py --model qwen2.5" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Installierte Modelle:"
try { ollama list } catch { Write-Host "   (ollama list fehlgeschlagen)" }
Write-Host ""
