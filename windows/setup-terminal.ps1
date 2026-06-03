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
# Variablen gefolgt von : immer als ${var}: schreiben! (Drive-Letter-Gotcha)
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
    $sym_ok   = "`u{2714}"
    $sym_err  = "`u{2716}"
    $sym_info = "`u{2139}"
    $sym_warn = "`u{26A0}"
    $sym_gear = "`u{2699}"
    $line_h   = "`u{2500}" * 60
    $box_top  = "`u{250C}" + "`u{2500}" * 58 + "`u{2510}"
    $box_bot  = "`u{2514}" + "`u{2500}" * 58 + "`u{2518}"
    $box_mid  = "`u{2502}"
} else {
    $sym_ok   = "[OK] "
    $sym_err  = "[ERR]"
    $sym_info = "[i]  "
    $sym_warn = "[!]  "
    $sym_gear = "[*]  "
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
    $psver = $PSVersionTable.PSVersion.ToString()
    $pstype = if ($IsPS7) { "pwsh 7.x" } else { "powershell 5.1" }
    Write-Host ("$box_mid  PS $psver  |  $pstype") -ForegroundColor Cyan
    Write-Host $box_bot -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param([string]$msg)
    Write-Host "  $sym_gear ${msg}" -ForegroundColor Yellow
}

function Write-OK { param([string]$msg)
    Write-Host "  $sym_ok ${msg}" -ForegroundColor Green
}

function Write-Err { param([string]$msg)
    Write-Host "  $sym_err ${msg}" -ForegroundColor Red
}

function Write-Info { param([string]$msg)
    Write-Host "  $sym_info ${msg}" -ForegroundColor Gray
}

function Write-Warn { param([string]$msg)
    Write-Host "  $sym_warn ${msg}" -ForegroundColor DarkYellow
}

function Write-Section { param([string]$title)
    Write-Host ""
    Write-Host "  $line_h" -ForegroundColor DarkCyan
    Write-Host "  ${title}" -ForegroundColor Cyan
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
# Tool pruefen + Pfad holen
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
# WICHTIG: "${Label}:" statt "$Label:" - Drive-Letter-Gotcha PS 5.1
# ----------------------------------------------------------------
function Install-WingetPackage { param([string]$Id, [string]$Label)
    Write-Step "Installiere ${Label} ..."
    try {
        winget install --id $Id --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-OK "${Label} installiert"
            return $true
        } else {
            $code = $LASTEXITCODE
            Write-Warn "${Label}: winget Exit-Code $code"
            return $false
        }
    } catch {
        $errMsg = $_.ToString()
        Write-Err "${Label}: $errMsg"
        return $false
    }
}

# ----------------------------------------------------------------
# Ollama starten und auf Port 11434 warten
# ----------------------------------------------------------------
function Start-OllamaServe {
    Write-Step "Starte ollama serve ..."
    $env:OLLAMA_VULKAN = "1"
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    # Warten bis Port offen ist (max 15 Sekunden)
    $waited = 0
    $ready  = $false
    while ($waited -lt 15) {
        Start-Sleep -Seconds 1
        $waited++
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", 11434)
            $tcp.Close()
            $ready = $true
            break
        } catch {
            # noch nicht bereit
        }
    }
    if ($ready) {
        Write-OK "ollama serve bereit (nach ${waited}s)  OLLAMA_VULKAN=1"
    } else {
        Write-Warn "ollama serve nach 15s noch nicht erreichbar"
    }
    return $ready
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

$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "Undefined") {
    Write-Step "Setze ExecutionPolicy CurrentUser -> RemoteSigned ..."
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-OK "ExecutionPolicy CurrentUser = RemoteSigned"
    } catch {
        $errMsg = $_.ToString()
        Write-Warn "ExecutionPolicy konnte nicht gesetzt werden: $errMsg"
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
        $errMsg = $_.ToString()
        Write-Warn "Unblock-File: $errMsg"
    }
} else {
    Write-Info "PSScriptRoot nicht gesetzt - Unblock uebersprungen"
}

# ----------------------------------------------------------------
# System-Info
# ----------------------------------------------------------------
Write-Section "System"
$osVersion = [System.Environment]::OSVersion.VersionString
$psVersion = $PSVersionTable.PSVersion.ToString()
$arch      = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
Write-Info "OS         : $osVersion"
Write-Info "PS-Version : $psVersion"
Write-Info "Arch       : $arch"

# GPU-Info (WMI - PS 5.1 + 7.x)
Write-Step "GPU-Info ..."
try {
    $gpus = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue
    if ($gpus) {
        foreach ($gpu in $gpus) {
            $ramMB   = [math]::Round($gpu.AdapterRAM / 1MB)
            $ramText = if ($gpu.AdapterRAM -gt 0) { "${ramMB} MB VRAM" } else { "VRAM unbekannt" }
            $gpuName = $gpu.Name
            $drvVer  = $gpu.DriverVersion
            Write-Info "GPU: ${gpuName}  |  ${ramText}  |  Driver: $drvVer"
        }
    } else {
        Write-Warn "Keine GPU-Info via WMI verfuegbar"
    }
} catch {
    $errMsg = $_.ToString()
    Write-Warn "GPU-Info Fehler: $errMsg"
}

# ----------------------------------------------------------------
# Ollama starten + GPU-Status pruefen
# ----------------------------------------------------------------
Write-Section "Ollama"

if (Test-Tool "ollama") {
    $ollamaPath = Get-ToolPath "ollama"
    Write-OK "Ollama gefunden: $ollamaPath"

    # Pruefen ob Ollama schon laeuft
    $alreadyRunning = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", 11434)
        $tcp.Close()
        $alreadyRunning = $true
    } catch { }

    if ($alreadyRunning) {
        Write-OK "ollama serve laeuft bereits auf Port 11434"
    } else {
        $started = Start-OllamaServe
        if (-not $started) {
            Write-Warn "Ollama manuell starten: ollama serve"
        }
    }

    # GPU-Status
    Write-Step "Ollama GPU-Status (ollama ps) ..."
    try {
        $ollamaPs = & ollama ps 2>&1
        $psText   = $ollamaPs -join " "
        if ($psText -match "GPU") {
            Write-OK "Ollama nutzt GPU-Speicher!"
        } elseif ($psText -match "CPU") {
            Write-Warn "Ollama laeuft auf CPU (kein GPU-Offloading aktiv)"
        } else {
            Write-Info "ollama ps: kein Modell geladen (normal wenn noch nichts gestartet)"
        }
    } catch {
        $errMsg = $_.ToString()
        Write-Warn "ollama ps Fehler: $errMsg"
    }

    # Server-Log Tipp
    $logPath = "$env:LOCALAPPDATA\Ollama\server.log"
    if (Test-Path $logPath) {
        Write-Info "Server-Log: Get-Content '$logPath' -Tail 20"
        # Letzte 5 Zeilen zeigen (GPU-Erkennung)
        $lastLines = Get-Content $logPath -Tail 5 -ErrorAction SilentlyContinue
        foreach ($line in $lastLines) {
            if ($line -match "GPU|gpu|VRAM|vram|vulkan|Vulkan|error|Error") {
                Write-Info "  LOG: $line"
            }
        }
    }
} else {
    Write-Warn "Ollama nicht gefunden - installieren:"
    Write-Info "  winget install Ollama.Ollama"
}

# ----------------------------------------------------------------
# Tools installieren
# ----------------------------------------------------------------
Write-Section "Tools pruefen / installieren"

if ($NoWinget) {
    Write-Info "winget-Installationen uebersprungen (-NoWinget)"
} elseif (-not (Test-Winget)) {
    Write-Warn "winget nicht verfuegbar:"
    Write-Info "  https://aka.ms/getwinget"
} else {
    Write-OK "winget verfuegbar"

    if (Test-Tool "git") {
        $p = Get-ToolPath "git"
        Write-OK "git: $p"
    } else {
        $null = Install-WingetPackage -Id "Git.Git" -Label "Git"
    }

    if (Test-Tool "pwsh") {
        $p = Get-ToolPath "pwsh"
        Write-OK "pwsh 7: $p"
    } else {
        Write-Warn "pwsh 7 nicht gefunden - empfohlen fuer besseren Output"
        if (-not $Silent) {
            $installPwsh = Read-Host "  PowerShell 7 installieren? [j/N]"
            if ($installPwsh -match "^[jJyY]") {
                $null = Install-WingetPackage -Id "Microsoft.PowerShell" -Label "PowerShell 7"
            } else {
                Write-Info "  Spaeter: winget install Microsoft.PowerShell"
            }
        }
    }

    if (Test-Tool "wt") {
        Write-OK "Windows Terminal: verfuegbar"
    } else {
        Write-Warn "Windows Terminal nicht gefunden"
        if (-not $Silent) {
            $installWT = Read-Host "  Windows Terminal installieren? [j/N]"
            if ($installWT -match "^[jJyY]") {
                $null = Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Label "Windows Terminal"
            } else {
                Write-Info "  Spaeter: winget install Microsoft.WindowsTerminal"
            }
        }
    }

    if (Test-Tool "py") {
        $p = Get-ToolPath "py"
        Write-OK "Python (py launcher): $p"
    } elseif (Test-Tool "python") {
        $p = Get-ToolPath "python"
        Write-OK "Python: $p"
    } else {
        Write-Warn "Python nicht gefunden:"
        Write-Info "  winget install Python.Python.3.11"
    }
}

# ----------------------------------------------------------------
# Windows Terminal Profil-Tipp
# ----------------------------------------------------------------
Write-Section "Windows Terminal Profil"
$cwd = (Get-Location).Path
Write-Info "Befehlszeile fuer WT-Profil:"
Write-Info "  pwsh -NoExit -Command `"cd '$cwd'; .\windows\chat.ps1`""
Write-Host ""

# ----------------------------------------------------------------
# Abschluss
# ----------------------------------------------------------------
Write-Section "Fertig"
Write-OK "Terminal-Bootstrap abgeschlossen"
Write-Info "Naechster Schritt: .\windows\chat.ps1"
Write-Host ""
Write-Info "GPU-Recherche-Stichworte:"
Write-Info "  ollama ps                      Modell-Status + GPU/CPU"
Write-Info "  OLLAMA_VULKAN=1                Vulkan-Backend aktivieren"
Write-Info "  ROCm min. GCN3 (RX 400+)       fuer AMD noetig"
Write-Info "  CUDA Toolkit                   fuer NVIDIA noetig"
Write-Host ""
