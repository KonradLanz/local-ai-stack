# =============================================================================
# windows/chat.ps1
# Shortcut-Skript fuer den Chat auf Windows
#
# Ausfuehren:
#   .\windows\chat.ps1
#   .\windows\chat.ps1 -Model qwen2.5:1.5b
#   .\windows\chat.ps1 -Model phi4-mini -Debug
#
# Voraussetzung: windows/install.ps1 wurde ausgefuehrt
# License: AGPL-3.0-or-later OR MIT  Copyright 2026 GrEEV.com KG
# =============================================================================
[CmdletBinding()]
param(
    [string]$Model   = '',
    [string]$System  = '',
    [switch]$Debug,
    [switch]$List
)
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$chatPy   = Join-Path $repoRoot 'lmstudio\chat_with_tools.py'

# LMS_HOST auf Ollama zeigen falls nicht gesetzt
if (-not $env:LMS_HOST) {
    $env:LMS_HOST = 'http://localhost:11434'
}

# Ollama-Server starten falls noetig
try {
    $null = Invoke-RestMethod "$env:LMS_HOST/v1/models" -TimeoutSec 3
} catch {
    Write-Host "Starte Ollama..." -ForegroundColor Yellow
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    Start-Sleep -Seconds 4
    # erneut pruefen
    try {
        $null = Invoke-RestMethod "$env:LMS_HOST/v1/models" -TimeoutSec 5
        Write-Host "Ollama laeuft." -ForegroundColor Green
    } catch {
        Write-Host "FEHLER: Ollama nicht erreichbar auf $env:LMS_HOST" -ForegroundColor Red
        Write-Host "Bitte 'ollama serve' manuell starten."
        exit 1
    }
}

# Python-Befehl zusammenbauen
$args_py = @()
if ($Model)  { $args_py += '--model'; $args_py += $Model }
if ($System) { $args_py += '--system'; $args_py += $System }
if ($Debug)  { $args_py += '--debug' }
if ($List)   { $args_py += '--list' }

# Python finden
$py = $null
foreach ($cmd in @('python','python3','py')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { $py = $cmd; break }
}
if (-not $py) {
    Write-Host "FEHLER: Python nicht gefunden." -ForegroundColor Red
    Write-Host "Bitte .\windows\install.ps1 ausfuehren."
    exit 1
}

Write-Host "Host   : $env:LMS_HOST" -ForegroundColor DarkGray
Write-Host "Skript : $chatPy" -ForegroundColor DarkGray
if ($env:PERPLEXITY_API_KEY) {
    Write-Host "Search : Perplexity" -ForegroundColor Green
} else {
    Write-Host "Search : DuckDuckGo (PERPLEXITY_API_KEY nicht gesetzt)" -ForegroundColor DarkGray
}
Write-Host ""

& $py $chatPy @args_py
