#!/usr/bin/env powershell
# ================================================================
#  local-ai-stack - Windows Bootstrap
#  Kompatibel mit PowerShell 5.1+ (Windows vorinstalliert) und 7+
#  Basiert auf ExecutionPolicy-Foundation v2.0.0 (GrEEV.com KG)
#
#  Ausfuehren:
#    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#    .\windows\install.ps1
#
#  SPDX-License-Identifier: (AGPL-3.0-or-later OR MIT)
# ================================================================
#Requires -Version 5.1

# UTF-8 fix (wichtig fuer Windows Terminal / PS5.1)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Alle PS1-Dateien im Verzeichnis entsperren (Download-Blocker)
try {
    if ($PSScriptRoot) {
        Get-ChildItem -Path $PSScriptRoot -Filter *.ps1 -ErrorAction SilentlyContinue |
            ForEach-Object { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue }
    }
} catch { }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Hilfsfunktionen ----
function Write-Step { param([string]$msg) Write-Host "" ; Write-Host ">> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "   OK  $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "   WARN  $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "   FAIL  $msg" -ForegroundColor Red }

# ---- Header ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  local-ai-stack  Windows Bootstrap" -ForegroundColor Cyan
Write-Host "  Ziel: Ollama + Python + Modelle fuer 8 GB RAM / 2 GB VRAM" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ---- ExecutionPolicy pruefen ----
Write-Step "ExecutionPolicy pruefen"
$machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy -ErrorAction SilentlyContinue
if ($machinePolicy -eq "Restricted") {
    Write-Fail "MachinePolicy ist Restricted (Group Policy). Bitte IT-Admin kontaktieren."
    exit 1
}
$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "Undefined") {
    Write-Warn "CurrentUser Policy ist $currentPolicy - setze auf RemoteSigned"
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Ok "ExecutionPolicy = RemoteSigned"
} else {
    Write-Ok "ExecutionPolicy = $currentPolicy"
}

# ---- Winget pruefen ----
Write-Step "Winget pruefen"
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetCmd) {
    $wgver = (winget --version 2>&1)
    Write-Ok "winget $wgver"
} else {
    Write-Warn "winget nicht gefunden - https://aka.ms/getwinget"
}

# ---- Ollama pruefen / installieren ----
Write-Step "Ollama pruefen / installieren"
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    $ollamaVer = (ollama --version 2>&1)
    Write-Ok "Ollama bereits installiert: $ollamaVer"
} else {
    Write-Host "   Ollama nicht gefunden. Installiere via winget..."
    if ($wingetCmd) {
        try {
            winget install -e --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH", "User")
            Write-Ok "Ollama installiert."
        } catch {
            Write-Warn "winget fehlgeschlagen."
            Write-Host "   Manuell: https://ollama.com/download/OllamaSetup.exe"
            Write-Host "   Danach dieses Skript erneut ausfuehren."
            exit 1
        }
    } else {
        Write-Fail "winget nicht verfuegbar. Bitte Ollama manuell installieren:"
        Write-Host "   https://ollama.com/download/OllamaSetup.exe"
        exit 1
    }
}

# ---- Python pruefen / installieren ----
Write-Step "Python pruefen"
$py = ""
$pyCandidates = @("python", "python3", "py")
foreach ($cmd in $pyCandidates) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        $ver = (& $cmd --version 2>&1)
        if ($ver -match "3\.(1[0-9]|[89])") {
            $py = $cmd
            Write-Ok "$cmd => $ver"
            break
        }
    }
}
if ($py -eq "") {
    Write-Warn "Python 3.8+ nicht gefunden."
    if ($wingetCmd) {
        try {
            winget install -e --id Python.Python.3.11 --silent --accept-package-agreements --accept-source-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH", "User")
            $py = "python"
            Write-Ok "Python 3.11 installiert."
        } catch {
            Write-Fail "Python-Install fehlgeschlagen. Manuell: https://python.org"
            exit 1
        }
    } else {
        Write-Fail "Bitte Python manuell installieren: https://python.org"
        exit 1
    }
}

# ---- Repo-Pfad ----
$repoRoot = Split-Path $PSScriptRoot -Parent
Write-Ok "Repo-Root: $repoRoot"

# ---- Ollama-Server starten (falls noetig) ----
Write-Step "Ollama-Server starten"
$ollamaRunning = $false
try {
    $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
    $ollamaRunning = $true
    Write-Ok "Ollama-Server laeuft bereits."
} catch {
    Write-Host "   Starte Ollama im Hintergrund..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 4
    $ollamaRunning = $true
    Write-Ok "Ollama gestartet."
}

# ---- Modelle pullen ----
Write-Step "Modelle pullen (8 GB RAM / 2 GB VRAM optimiert)"

$modelList = @(
    "qwen2.5:1.5b",
    "phi4-mini"
)
$modelReasons = @{
    "qwen2.5:1.5b" = "Bestes Tool-Calling unter 2 GB RAM - Empfehlung"
    "phi4-mini"    = "Guter Allrounder ca. 2.5 GB RAM"
}

foreach ($modelName in $modelList) {
    $reason = $modelReasons[$modelName]
    Write-Host "   Pulling $modelName  ($reason)..."
    try {
        ollama pull $modelName
        Write-Ok $modelName
    } catch {
        Write-Warn "Konnte $modelName nicht pullen: $_"
    }
}

# ---- LMS_HOST Umgebungsvariable ----
Write-Step "LMS_HOST setzen (User-scope, permanent)"
[System.Environment]::SetEnvironmentVariable("LMS_HOST", "http://localhost:11434", "User")
$env:LMS_HOST = "http://localhost:11434"
Write-Ok "LMS_HOST=http://localhost:11434"

# ---- Abschluss ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host "================================================================"
Write-Host ""
Write-Host "  Naechste Schritte:"
Write-Host ""
Write-Host "  1. Neues PowerShell-Fenster oeffnen (LMS_HOST wirkt dann)"
Write-Host ""
Write-Host "  2. Chat starten:" 
Write-Host "       .\windows\chat.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Oder direkt:"
Write-Host "       python lmstudio\chat_with_tools.py --model qwen2.5" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Installierte Modelle:"
try {
    ollama list
} catch {
    Write-Host "   (ollama list fehlgeschlagen)"
}
Write-Host ""
