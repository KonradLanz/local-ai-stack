#Requires -Version 5.1
# ================================================================
#  local-ai-stack - Terminal Bootstrap
#  Based on ExecutionPolicy-Foundation v2.0.0 (GrEEV.com KG)
#  PS 5.1 kompatibel - schoenerer Output unter pwsh 7.x
#  License: AGPL-3.0-or-later OR MIT
#  SPDX-License-Identifier: (AGPL-3.0-or-later OR MIT)
# ================================================================
# WICHTIG: Nur plain ASCII-Quotes verwenden (PS 5.1 Parser-Gotcha)
# Kein ?.  kein ??=  kein ?[]  (PS 7.1+ only)
# Kein &&  kein ||   (PS 7.0+ only)
# Kein $x ? $a : $b  (PS 7.0+ only)
# ================================================================

param(
    [switch]$Silent,
    [switch]$NoWinget,
    [switch]$Force
)

# ----------------------------------------------------------------
# UTF-8 Output (Foundation-Pattern)
# ----------------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ----------------------------------------------------------------
# PS-Version ermitteln - ohne ?.  (PS 5.1 kompatibel)
# ----------------------------------------------------------------
$PSMajor = $PSVersionTable.PSVersion.Major
$IsPS7   = ($PSMajor -ge 7)

# ----------------------------------------------------------------
# Farben & Symbole - PS7 bekommt Unicode, PS5.1 ASCII-Fallback
# ----------------------------------------------------------------
if ($IsPS7) {
    $sym_ok   = "`u{2714}"   # checkmark
    $sym_err  = "`u{2716}"   # cross
    $sym_info = "`u{2139}"   # info
    $sym_warn = "`u{26A0}"   # warning
    $sym_gear = "`u{2699}"   # gear
    $line_h   = "`u{2500}" * 60
    $box_top  = "`u{250C}" + "`u{2500}" * 58 + "`u{2510}"
    $box_bot  = "`u{2514}" + "`u{2500}" * 58 + "`u{2518}"
    $box_mid  = "`u{2502}"
} else {
    $sym_ok   = "[OK]"
    $sym_err  = "[ERR]"
    $sym_info = "[i]"
    $sym_warn = "[!]"
    $sym_gear = "[*]"
    $line_h   = "=" * 60
    $box_top  = "+" + "-" * 58 + "+"
    $box_bot  = "+" + "-" * 58 + "+"
    $box_mid  = "|"
}

# ----------------------------------------------------------------
# Helper-Funktionen
# ----------------------------------------------------------------
function Write-Banner {
    Write-Host ""
    Write-Host $box_top -ForegroundColor Cyan
    Write-Host ("$box_mid  local-ai-stack - Terminal Bootstrap") -ForegroundColor Cyan
    Write-Host ("$box_mid  Based on ExecutionPolicy-Foundation v2.0.0 (GrEEV.com KG)") -ForegroundColor Cyan
    Write-Host ("$box_mid  PS $($PSVersionTable.PSVersion)  |  $(if ($IsPS7) { 'pwsh 7.x' } else { 'powershell 5.1' })") -ForegroundColor Cyan
    Write-Host $box_bot -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$msg)
    Write-Host "  $sym_gear $msg" -ForegroundColor Yellow
}

function Write-OK { param([string]$msg)
    Write-Host "  $sym_ok $msg" -ForegroundColor Green
}

function Write-Err { param([string]$msg)
    Write-Host "  $sym_err $msg" -ForegroundColor Red
}

function Write-Info { param([string]$msg)
    Write-Host "  $sym_info $msg" -ForegroundColor Gray
}

function Write-Warn { param([string]$msg)
    Write-Host "  $sym_warn $msg" -ForegroundColor DarkYellow
}

function Write-Section { param([string]$title)
    Write-Host ""
    Write-Host "  $line_h" -ForegroundColor DarkCyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "  $line_h" -ForegroundColor DarkCyan
}

# ----------------------------------------------------------------
# winget-Verfuegbarkeit pruefen (PS 5.1 kompatibel - kein ?.)
# ----------------------------------------------------------------
function Test-Winget {
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if ($wg) { return $true }
    return $false
}

# ----------------------------------------------------------------
# Tool pruefen: gibt $true / $false zurueck
# PS 5.1 kompatibel - kein $cmd?.Source
# ----------------------------------------------------------------
function Test-Tool { param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    return $false
}

function Get-ToolPath { param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

# ----------------------------------------------------------------
# winget-Install mit Fehlerbehandlung
# ----------------------------------------------------------------
function Install-WingetPackage { param([string]$Id, [string]$Label)
    Write-Step "Installiere $Label ..."
    try {
        winget install --id $Id --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-OK "$Label installiert"
            return $true
        } else {
            Write-Warn "$Label: winget Exit-Code $LASTEXITCODE"
            return $false
        }
    } catch {
        Write-Err "$Label: $_"
        return $false
    }
}

# ================================================================
# MAIN
# ================================================================
Write-Banner

# ----------------------------------------------------------------
# ExecutionPolicy Check (Foundation-Pattern)
# ----------------------------------------------------------------
Write-Section "ExecutionPolicy"
Write-Step "Pruefe ExecutionPolicy ..."

$machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy -ErrorAction SilentlyContinue
if ($machinePolicy -eq "Restricted") {
    Write-Err "Group Policy hat ExecutionPolicy auf Restricted gesperrt."
    Write-Info "Bitte IT-Admin kontaktieren."
    exit 1
}
Write-OK "ExecutionPolicy: OK"

# Lokale Policy fuer den User lockern falls noetig
$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "Undefined") {
    Write-Step "Setze ExecutionPolicy CurrentUser -> RemoteSigned ..."
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-OK "ExecutionPolicy CurrentUser = RemoteSigned"
    } catch {
        Write-Warn "ExecutionPolicy konnte nicht gesetzt werden: $_"
    }
} else {
    Write-OK "ExecutionPolicy CurrentUser = $currentPolicy"
}

# ----------------------------------------------------------------
# Auto-Unblock (Foundation-Pattern)
# ----------------------------------------------------------------
Write-Section "Unblock Scripts"
if ($PSScriptRoot) {
    try {
        $ps1files = Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
        foreach ($f in $ps1files) {
            Unblock-File -Path $f.FullName -ErrorAction SilentlyContinue
        }
        Write-OK "Alle .ps1 Dateien in $PSScriptRoot entsperrt"
    } catch {
        Write-Warn "Unblock-File: $_"
    }
} else {
    Write-Info "PSScriptRoot nicht gesetzt - Unblock uebersprungen"
}

# ----------------------------------------------------------------
# System-Info
# ----------------------------------------------------------------
Write-Section "System"
Write-Info "OS        : $([System.Environment]::OSVersion.VersionString)"
Write-Info "PS-Version: $($PSVersionTable.PSVersion)"
Write-Info "Arch      : $([System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE'))"

# GPU-Info (WMI - PS 5.1 + 7.x)
Write-Step "GPU-Info ..."
try {
    $gpus = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue
    if ($gpus) {
        foreach ($gpu in $gpus) {
            $ramMB = [math]::Round($gpu.AdapterRAM / 1MB)
            $ramText = if ($gpu.AdapterRAM -gt 0) { "${ramMB} MB VRAM" } else { "VRAM unbekannt" }
            Write-Info "GPU: $($gpu.Name)  |  $ramText  |  Driver: $($gpu.DriverVersion)"
        }
    } else {
        Write-Warn "Keine GPU-Info via WMI verfuegbar"
    }
} catch {
    Write-Warn "GPU-Info Fehler: $_"
}

# Ollama GPU-Status
Write-Step "Ollama GPU-Status ..."
if (Test-Tool "ollama") {
    Write-Info "Ollama: $(Get-ToolPath 'ollama')"
    try {
        $ollamaPs = & ollama ps 2>&1
        if ($ollamaPs -match "GPU") {
            Write-OK "Ollama nutzt GPU-Speicher"
        } elseif ($ollamaPs -match "CPU") {
            Write-Warn "Ollama laeuft auf CPU (kein GPU-Offloading aktiv)"
            Write-Info "Siehe: https://ollama.com/blog/windows-preview fuer GPU-Setup"
        } else {
            Write-Info "ollama ps: $ollamaPs"
        }
    } catch {
        Write-Warn "ollama ps: $_"
    }
} else {
    Write-Warn "Ollama nicht gefunden"
}

# ----------------------------------------------------------------
# Tools installieren
# ----------------------------------------------------------------
Write-Section "Tools pruefen / installieren"

if ($NoWinget) {
    Write-Info "winget-Installationen uebersprungen (-NoWinget)"
} elseif (-not (Test-Winget)) {
    Write-Warn "winget nicht verfuegbar - bitte manuell installieren:"
    Write-Info "  https://aka.ms/getwinget"
} else {
    Write-OK "winget verfuegbar"

    # git
    if (Test-Tool "git") {
        $gitPath = Get-ToolPath "git"
        Write-OK "git: $gitPath"
    } else {
        Install-WingetPackage -Id "Git.Git" -Label "Git"
    }

    # pwsh 7 (optional, fuer schoeneren Output)
    if (Test-Tool "pwsh") {
        $pwshPath = Get-ToolPath "pwsh"
        Write-OK "pwsh 7: $pwshPath"
    } else {
        Write-Warn "pwsh 7 nicht gefunden - installieren fuer besseren Output:"
        if (-not $Silent) {
            $installPwsh = Read-Host "  PowerShell 7 installieren? [j/N]"
            if ($installPwsh -match "^[jJyY]") {
                Install-WingetPackage -Id "Microsoft.PowerShell" -Label "PowerShell 7"
            } else {
                Write-Info "  winget install Microsoft.PowerShell (spaeter nachholen)"
            }
        }
    }

    # Windows Terminal (optional)
    if (Test-Tool "wt") {
        Write-OK "Windows Terminal: verfuegbar"
    } else {
        Write-Warn "Windows Terminal nicht gefunden:"
        if (-not $Silent) {
            $installWT = Read-Host "  Windows Terminal installieren? [j/N]"
            if ($installWT -match "^[jJyY]") {
                Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Label "Windows Terminal"
            } else {
                Write-Info "  winget install Microsoft.WindowsTerminal (spaeter nachholen)"
            }
        }
    }

    # Python pruefen
    if (Test-Tool "py") {
        $pyPath = Get-ToolPath "py"
        Write-OK "Python (py launcher): $pyPath"
    } elseif (Test-Tool "python") {
        $pyPath = Get-ToolPath "python"
        Write-OK "Python: $pyPath"
    } else {
        Write-Warn "Python nicht gefunden:"
        Write-Info "  winget install Python.Python.3.11"
    }
}

# ----------------------------------------------------------------
# Windows Terminal Profil-Tipp (nur Info)
# ----------------------------------------------------------------
Write-Section "Windows Terminal Profil-Tipp"
Write-Info "Fuer einen dedizierten 'local-ai-stack' Profil in Windows Terminal:"
Write-Info "  1. Windows Terminal oeffnen -> Einstellungen -> Profil hinzufuegen"
Write-Info "  2. Name: local-ai-stack"
Write-Info "  3. Befehlszeile: pwsh -NoExit -Command \"cd '$((Get-Location).Path)'; .\\windows\\chat.ps1\""
Write-Info "  4. Symbol: z.B. ein Roboter-Emoji oder Pfad zu Icon"
Write-Host ""
if ($IsPS7) {
    Write-Host "  Oder als JSON-Fragment fuer settings.json:" -ForegroundColor Gray
    $profileJson = @"

  {
    "name": "local-ai-stack",
    "commandline": "pwsh -NoExit -Command \"cd '$((Get-Location).Path)'; .\\\\windows\\\\chat.ps1\"",
    "startingDirectory": "$((Get-Location).Path.Replace('\', '\\'))",
    "colorScheme": "One Half Dark",
    "icon": "`u{1F916}"
  }
"@
    Write-Host $profileJson -ForegroundColor DarkGray
}

# ----------------------------------------------------------------
# Abschluss
# ----------------------------------------------------------------
Write-Section "Fertig"
Write-OK "Terminal-Bootstrap abgeschlossen"
Write-Info "Naechster Schritt: .\windows\chat.ps1"
Write-Host ""
Write-Info "GPU-Speicher aktivieren -> Recherche-Stichworte:"
Write-Info "  ollama ps                    (aktueller Modell-Status)"
Write-Info "  nvidia-smi                   (NVIDIA VRAM-Auslastung)"
Write-Info "  OLLAMA_GPU_LAYERS env-var    (Layer-Offloading steuern)"
Write-Info "  CUDA Toolkit + cuDNN         (NVIDIA-Setup)"
Write-Info "  ROCm fuer AMD GPUs           (AMD-Alternative zu CUDA)"
Write-Info "  Ollama GGUF Quantisierung    (Q4_K_M passt besser in VRAM)"
Write-Host ""
