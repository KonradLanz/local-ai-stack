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
#  Idempotent: kann beliebig oft ausgefuehrt werden ohne Reinstallationen
#  SPDX-License-Identifier: (AGPL-3.0-or-later OR MIT)
# ================================================================
#Requires -Version 5.1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
function Write-Skip { param([string]$msg) Write-Host "   --  $msg" -ForegroundColor DarkGray }
function Write-Warn { param([string]$msg) Write-Host "   WARN  $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "   FAIL  $msg" -ForegroundColor Red }

# ----------------------------------------------------------------
# Testet ob ein Kommando ein echter Python-Interpreter ist
# (kein Windows-Store-Stub aus WindowsApps\python.exe)
# Gibt Versions-String zurueck oder "" wenn Stub/nicht gefunden
# ----------------------------------------------------------------
function Test-RealPython {
    param([string]$cmd)
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $found) { return "" }
    if ($found.Source -like "*WindowsApps*") { return "" }
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $ver = ""
    try {
        $output = (& $cmd --version 2>&1)
        if ($output -match "^Python 3\.(1[0-9]|[89])") {
            $ver = $output.ToString().Trim()
        }
    } catch { }
    $ErrorActionPreference = $oldPref
    return $ver
}

# ----------------------------------------------------------------
# Prueft ob ein Ollama-Modell lokal vorhanden ist
# (ollama list gibt Tabelle aus - wir suchen den Modell-Namen)
# ----------------------------------------------------------------
function Test-OllamaModel {
    param([string]$modelName)
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $found = $false
    try {
        $list = (ollama list 2>&1)
        # ollama list gibt Zeilen wie: "qwen2.5:1.5b   abc123   986 MB   2 hours ago"
        foreach ($line in $list) {
            if ($line -match ("^" + [regex]::Escape($modelName))) {
                $found = $true
                break
            }
        }
    } catch { }
    $ErrorActionPreference = $oldPref
    return $found
}

# ---- Header ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  local-ai-stack  Windows Bootstrap" -ForegroundColor Cyan
Write-Host "  Ziel: Ollama + Python + Modelle fuer 8 GB RAM / 2 GB VRAM" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ---- ExecutionPolicy ----
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
    Write-Skip "ExecutionPolicy = $currentPolicy (ok)"
}

# ---- Winget ----
Write-Step "Winget pruefen"
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetCmd) {
    $wgver = (winget --version 2>&1)
    Write-Skip "winget $wgver (bereits vorhanden)"
} else {
    Write-Warn "winget nicht gefunden - https://aka.ms/getwinget"
}

# ---- Ollama ----
Write-Step "Ollama pruefen / installieren"
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    $ollamaVer = (ollama --version 2>&1)
    Write-Skip "Ollama $ollamaVer (bereits installiert)"
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
            exit 1
        }
    } else {
        Write-Fail "winget nicht verfuegbar."
        Write-Host "   Manuell: https://ollama.com/download/OllamaSetup.exe"
        exit 1
    }
}

# ---- Python ----
# Windows 10/11 Store-Stub (WindowsApps\python.exe) wird herausgefiltert
Write-Step "Python pruefen / installieren"
$py = ""
foreach ($cmd in @("python3", "python", "py")) {
    $ver = Test-RealPython $cmd
    if ($ver -ne "") {
        $py = $cmd
        Write-Skip "$cmd => $ver (bereits installiert)"
        break
    }
}

if ($py -eq "") {
    Write-Host "   Kein echter Python 3.8+ Interpreter gefunden. Installiere Python 3.11..."
    if ($wingetCmd) {
        try {
            winget install -e --id Python.Python.3.11 --silent `
                --accept-package-agreements --accept-source-agreements `
                --override "/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1"
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH", "User")
            Start-Sleep -Seconds 3
            $ver = Test-RealPython "python"
            if ($ver -ne "") {
                $py = "python"
                Write-Ok "Python installiert: $ver"
            } else {
                $ver = Test-RealPython "py"
                if ($ver -ne "") {
                    $py = "py"
                    Write-Ok "Python installiert (via py launcher): $ver"
                } else {
                    Write-Warn "Python installiert aber noch nicht im PATH."
                    Write-Warn "Bitte PowerShell-Fenster schliessen, neu oeffnen und Skript erneut ausfuehren."
                    exit 0
                }
            }
        } catch {
            Write-Fail "Python-Install fehlgeschlagen: $_"
            Write-Host "   Manuell: https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
            Write-Host "   Wichtig: Haken bei 'Add Python to PATH' setzen!"
            exit 1
        }
    } else {
        Write-Fail "winget nicht verfuegbar."
        Write-Host "   Manuell: https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
        exit 1
    }
}

# ---- pip + Basis-Pakete (idempotent: nur installieren wenn fehlen) ----
Write-Step "pip und Basis-Pakete pruefen"
try {
    # pip selbst aktualisieren nur wenn noetig (kein --upgrade = kein Netz-Check wenn aktuell)
    $pipCheck = (& $py -m pip install pip --quiet 2>&1)
    # requests + httpx: pip installiert nur wenn noch nicht vorhanden
    $pkgCheck = (& $py -m pip install requests httpx --quiet 2>&1)
    # Pruefen ob wirklich was installiert wurde oder alles schon da war
    $installed = @()
    foreach ($line in $pkgCheck) {
        if ($line -match "^Successfully installed") { $installed += $line }
    }
    if ($installed.Count -gt 0) {
        Write-Ok "Pakete installiert: $installed"
    } else {
        Write-Skip "requests, httpx bereits vorhanden"
    }
} catch {
    Write-Warn "pip-Check fehlgeschlagen (nicht kritisch): $_"
}

# ---- Repo-Pfad ----
$repoRoot = Split-Path $PSScriptRoot -Parent
Write-Ok "Repo-Root: $repoRoot"

# ---- Ollama-Server starten (falls noetig) ----
Write-Step "Ollama-Server pruefen"
try {
    $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
    Write-Skip "Ollama-Server laeuft bereits."
} catch {
    Write-Host "   Starte Ollama im Hintergrund..."
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Write-Ok "Ollama gestartet."
}

# ---- Modelle pullen (nur wenn nicht lokal vorhanden) ----
Write-Step "Modelle pruefen / pullen"

$modelList = @(
    "qwen2.5:1.5b",
    "phi4-mini"
)
$modelReasons = @{
    "qwen2.5:1.5b" = "Bestes Tool-Calling unter 2 GB RAM"
    "phi4-mini"    = "Guter Allrounder ca. 2.5 GB RAM"
}

foreach ($modelName in $modelList) {
    $reason = $modelReasons[$modelName]
    if (Test-OllamaModel $modelName) {
        Write-Skip "$modelName bereits lokal vorhanden"
    } else {
        Write-Host "   Pulling $modelName  ($reason)..."
        try {
            ollama pull $modelName
            Write-Ok "$modelName gepullt."
        } catch {
            Write-Warn "Konnte $modelName nicht pullen: $_"
        }
    }
}

# ---- LMS_HOST Umgebungsvariable ----
Write-Step "LMS_HOST pruefen"
$existingHost = [System.Environment]::GetEnvironmentVariable("LMS_HOST", "User")
if ($existingHost -eq "http://localhost:11434") {
    Write-Skip "LMS_HOST bereits gesetzt."
} else {
    [System.Environment]::SetEnvironmentVariable("LMS_HOST", "http://localhost:11434", "User")
    Write-Ok "LMS_HOST=http://localhost:11434"
}
$env:LMS_HOST = "http://localhost:11434"

# ---- Abschluss ----
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host "================================================================"
Write-Host ""
Write-Host "  Naechste Schritte:"
Write-Host ""
Write-Host "  1. Neues PowerShell-Fenster oeffnen (PATH + LMS_HOST wirken dann)"
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
