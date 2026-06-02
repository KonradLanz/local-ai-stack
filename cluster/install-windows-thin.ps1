# =============================================================================
# cluster/install-windows-thin.ps1
# Windows thin node setup (8-16GB RAM + GPU)
# License: AGPL-3.0-or-later OR MIT  Copyright 2026 GrEEV.com KG
#
# Usage:
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\cluster\install-windows-thin.ps1
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir

function Write-Step  { param($m) Write-Host "[STEP]  $m" -ForegroundColor Cyan    }
function Write-Info  { param($m) Write-Host "[WIN]   $m" -ForegroundColor Green   }
function Write-Warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow  }
function Write-Fail  { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# 1. Load shared hardware detection from bootstrap-foundation
# ---------------------------------------------------------------------------
Write-Step "Loading hardware detection from bootstrap-foundation..."

$BfRoot = if ($env:BOOTSTRAP_FOUNDATION) { $env:BOOTSTRAP_FOUNDATION } \
          else { Join-Path (Split-Path -Parent $RepoRoot) 'bootstrap-foundation' }
$HwLib  = Join-Path $BfRoot 'lib\detect-hardware.ps1'

if (-not (Test-Path $HwLib)) {
    Write-Warn "bootstrap-foundation not found at $BfRoot"
    Write-Warn "Cloning bootstrap-foundation..."
    $cloneTarget = Join-Path (Split-Path -Parent $RepoRoot) 'bootstrap-foundation'
    git clone https://github.com/KonradLanz/bootstrap-foundation.git $cloneTarget 2>&1 | Out-Null
    $HwLib = Join-Path $cloneTarget 'lib\detect-hardware.ps1'
}

. $HwLib
$hw = Detect-Hardware
Print-HwSummary -hw $hw

# Force windows-thin profile
if ($hw.NodeProfile -eq 'micro' -or $hw.NodeProfile -eq 'secondary') {
    Write-Warn "Auto-profile is '$($hw.NodeProfile)' — overriding to 'windows-thin' for this setup."
    $hw.NodeProfile = 'windows-thin'
}

# ---------------------------------------------------------------------------
# 2. Model selection based on VRAM
# ---------------------------------------------------------------------------
Write-Step "Selecting model for InferenceMB=$($hw.InferenceMB)..."

$model = if     ($hw.InferenceMB -ge 6144) { 'llama3.2:3b'     }
         elseif ($hw.InferenceMB -ge 3072) { 'phi3.5-mini'     }
         elseif ($hw.InferenceMB -ge 1024) { 'qwen2.5:1.5b'    }
         else                              { 'qwen2.5:0.5b'    }

Write-Info "Model selected: $model (InferenceMB=$($hw.InferenceMB))"

# ---------------------------------------------------------------------------
# 3. Install Ollama
# ---------------------------------------------------------------------------
Write-Step "Installing Ollama..."

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCmd) {
    Write-Info "Downloading Ollama MSI..."
    $msiUrl  = 'https://ollama.com/download/OllamaSetup.exe'
    $msiPath = "$env:TEMP\OllamaSetup.exe"
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Write-Info "Running Ollama installer silently..."
    Start-Process -FilePath $msiPath -ArgumentList '/SILENT' -Wait
    $env:PATH += ";$env:LOCALAPPDATA\Programs\Ollama"
} else {
    Write-Info "Ollama already installed: $(ollama --version 2>&1)"
}

# ---------------------------------------------------------------------------
# 4. Configure Ollama environment (localhost-only on thin nodes)
# ---------------------------------------------------------------------------
Write-Step "Configuring Ollama environment..."
[System.Environment]::SetEnvironmentVariable('OLLAMA_HOST',    '127.0.0.1:11434', 'User')
[System.Environment]::SetEnvironmentVariable('OLLAMA_ORIGINS', '*',               'User')

# ---------------------------------------------------------------------------
# 5. Create Task Scheduler entry (auto-start at login)
# ---------------------------------------------------------------------------
Write-Step "Creating Task Scheduler entry for Ollama auto-start..."
try {
    $action   = New-ScheduledTaskAction -Execute 'ollama' -Argument 'serve'
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3
    $envVars  = @{ OLLAMA_HOST = '127.0.0.1:11434'; OLLAMA_ORIGINS = '*' }
    Register-ScheduledTask -TaskName 'LocalAI-Ollama' `
        -Action $action -Trigger $trigger -Settings $settings `
        -RunLevel Highest -Force | Out-Null
    Write-Info "Task 'LocalAI-Ollama' registered (runs at login)"
} catch {
    Write-Warn "Task Scheduler failed: $_"
    Write-Warn "Start Ollama manually: ollama serve"
}

# ---------------------------------------------------------------------------
# 6. Start Ollama now
# ---------------------------------------------------------------------------
Write-Step "Starting Ollama..."
$env:OLLAMA_HOST    = '127.0.0.1:11434'
$env:OLLAMA_ORIGINS = '*'
Start-Process -FilePath 'ollama' -ArgumentList 'serve' -NoNewWindow
Start-Sleep -Seconds 4

# ---------------------------------------------------------------------------
# 7. Pull model
# ---------------------------------------------------------------------------
Write-Step "Pulling model: $model..."
ollama pull $model

# ---------------------------------------------------------------------------
# 8. Write hw-profile.json for discover.py
# ---------------------------------------------------------------------------
Write-Step "Writing hardware profile..."
$profileDir = Join-Path $RepoRoot 'cluster'
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
$jsonOut = Join-Path $profileDir 'hw-profile.json'
HW-ToJson -hw $hw | Out-File -Encoding utf8 -FilePath $jsonOut
Write-Info "Hardware profile written: $jsonOut"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Windows thin node ready!" -ForegroundColor Green
Write-Host ""
Write-Host "  Model loaded  : $model"
Write-Host "  InferenceMB   : $($hw.InferenceMB) MB ($($hw.GpuVendor) GPU)"
Write-Host "  Ollama        : http://127.0.0.1:11434 (localhost only)"
Write-Host ""
Write-Host "  pfsense DHCP reservation:"
Write-Host "    MAC: $($hw.MacAddress)"
Write-Host "    Assign a fixed IP in pfsense Services > DHCP > Static Mappings"
Write-Host ""
Write-Host "  After reservation: update cluster/network-map.yaml on PRIMARY"
Write-Host "  Then on PRIMARY: python3 cluster/discover.py --once"
Write-Host "============================================================" -ForegroundColor Cyan
