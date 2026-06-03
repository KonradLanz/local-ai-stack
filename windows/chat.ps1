#!/usr/bin/env powershell
# =============================================================================
# windows/chat.ps1
# Shortcut-Skript fuer den Chat auf Windows
#
# Ausfuehren:
#   .\windows\chat.ps1
#   .\windows\chat.ps1 -Model qwen2.5:1.5b
#   .\windows\chat.ps1 -Model phi4-mini -DebugMode
#
# Voraussetzung: windows/install.ps1 wurde ausgefuehrt
# License: AGPL-3.0-or-later OR MIT  Copyright 2026 GrEEV.com KG
# =============================================================================
#Requires -Version 5.1
# HINWEIS: Kein [CmdletBinding()] - wuerde -Debug als Common Parameter
# hinzufuegen und mit eigenem -DebugMode kollidieren (PS5.1 MetadataException)
param(
    [string]$Model     = '',
    [string]$System    = '',
    [switch]$DebugMode,
    [switch]$List
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------
# Prueft ob ein python-Kommando ein echter Interpreter ist
# (filtert Windows Store-Stub aus WindowsApps heraus)
# ----------------------------------------------------------------
function Find-Python {
    foreach ($cmd in @('py', 'python3', 'python')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if (-not $found) { continue }
        if ($found.Source -like "*WindowsApps*") { continue }
        $oldPref = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        try {
            $output = (& $cmd --version 2>&1)
            if ($output -match "^Python 3\.(1[0-9]|[89])") {
                $ErrorActionPreference = $oldPref
                return $cmd
            }
        } catch { }
        $ErrorActionPreference = $oldPref
    }
    return ""
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$chatPy   = Join-Path $repoRoot 'lmstudio\chat_with_tools.py'

# LMS_HOST auf Ollama zeigen falls nicht gesetzt
if (-not $env:LMS_HOST) {
    $env:LMS_HOST = 'http://localhost:11434'
}

# Ollama-Server starten falls noetig
$ollamaOk = $false
try {
    $null = Invoke-RestMethod "$env:LMS_HOST/v1/models" -TimeoutSec 3
    $ollamaOk = $true
} catch { }

if (-not $ollamaOk) {
    Write-Host "Starte Ollama..." -ForegroundColor Yellow
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    Start-Sleep -Seconds 4
    try {
        $null = Invoke-RestMethod "$env:LMS_HOST/v1/models" -TimeoutSec 5
        Write-Host "Ollama laeuft." -ForegroundColor Green
    } catch {
        Write-Host "FEHLER: Ollama nicht erreichbar auf $env:LMS_HOST" -ForegroundColor Red
        Write-Host "Bitte 'ollama serve' manuell starten."
        exit 1
    }
}

# Python finden (Store-Stub wird uebersprungen)
$py = Find-Python
if ($py -eq "") {
    Write-Host "FEHLER: Kein echter Python 3.8+ Interpreter gefunden." -ForegroundColor Red
    Write-Host "Bitte .\windows\install.ps1 ausfuehren."
    exit 1
}

# Argumente fuer Python-Skript zusammenbauen
$pyArgs = @($chatPy)
if ($Model)     { $pyArgs += '--model';  $pyArgs += $Model }
if ($System)    { $pyArgs += '--system'; $pyArgs += $System }
if ($DebugMode) { $pyArgs += '--debug' }
if ($List)      { $pyArgs += '--list' }

Write-Host "Host   : $env:LMS_HOST" -ForegroundColor DarkGray
Write-Host "Python : $py" -ForegroundColor DarkGray
Write-Host "Skript : $chatPy" -ForegroundColor DarkGray
if ($env:PERPLEXITY_API_KEY) {
    Write-Host "Search : Perplexity" -ForegroundColor Green
} else {
    Write-Host "Search : DuckDuckGo (PERPLEXITY_API_KEY nicht gesetzt)" -ForegroundColor DarkGray
}
Write-Host ""

& $py @pyArgs
