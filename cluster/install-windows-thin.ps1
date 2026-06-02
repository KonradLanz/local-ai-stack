# =============================================================================
# cluster/install-windows-thin.ps1
# Windows thin node setup (8-16GB RAM, 2GB+ VRAM)
# Run in PowerShell as Administrator:
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\cluster\install-windows-thin.ps1
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

function Info  { param($msg) Write-Host "[WIN-THIN] $msg" -ForegroundColor Cyan }
function Warn  { param($msg) Write-Host "[WARN]     $msg" -ForegroundColor Yellow }
function Ok    { param($msg) Write-Host "  OK  $msg" -ForegroundColor Green }

Info "=== local-ai-stack Windows thin node setup ==="
Info "Role: tiny-gpu worker, proxy to PRIMARY for heavy tasks"

# ---------------------------------------------------------------------------
# 1. Check if running as Administrator
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())
              .IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Warn "Not running as Administrator. Some steps may fail."
  Warn "Restart PowerShell as Administrator for full setup."
}

# ---------------------------------------------------------------------------
# 2. Install Ollama
# ---------------------------------------------------------------------------
$ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Get-Command ollama -ErrorAction SilentlyContinue) -and -not (Test-Path $ollamaExe)) {
  Info "Downloading Ollama installer..."
  $installerUrl = "https://ollama.com/download/OllamaSetup.exe"
  $installerPath = "$env:TEMP\OllamaSetup.exe"
  Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
  Info "Running Ollama installer (silent)..."
  Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
  Ok "Ollama installed"
} else {
  Ok "Ollama already installed"
}

# Add Ollama to PATH for this session if needed
$ollamaDir = "$env:LOCALAPPDATA\Programs\Ollama"
if ($env:PATH -notlike "*$ollamaDir*") {
  $env:PATH = "$env:PATH;$ollamaDir"
}

# ---------------------------------------------------------------------------
# 3. Configure Ollama host (localhost only on Windows thin nodes)
# ---------------------------------------------------------------------------
Info "Configuring Ollama to localhost:11434..."
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", "127.0.0.1:11434", "User")
[System.Environment]::SetEnvironmentVariable("OLLAMA_ORIGINS", "*", "User")
Ok "OLLAMA_HOST set to 127.0.0.1:11434"

# ---------------------------------------------------------------------------
# 4. Detect GPU and recommend model
# ---------------------------------------------------------------------------
Info "Detecting GPU..."
try {
  $gpu = Get-WmiObject Win32_VideoController | Select-Object -First 1
  $vramBytes = $gpu.AdapterRAM
  $vramGB = [math]::Round($vramBytes / 1GB, 1)
  Info "GPU: $($gpu.Name) | VRAM: ${vramGB}GB"

  if ($vramGB -ge 4) {
    $recommendedModel = "phi3.5-mini:latest"  # ~2.2GB VRAM
    Info "Recommended model: $recommendedModel (fits in ${vramGB}GB VRAM)"
  } elseif ($vramGB -ge 2) {
    $recommendedModel = "qwen2.5:1.5b-instruct-q4_K_M"  # ~1.1GB VRAM
    Info "Recommended model: $recommendedModel (fits in 2GB VRAM)"
  } else {
    $recommendedModel = "qwen2.5:1.5b"  # CPU fallback
    Warn "VRAM < 2GB detected. Model will run on CPU (slow)."
  }
} catch {
  $recommendedModel = "qwen2.5:1.5b"
  Warn "GPU detection failed. Defaulting to qwen2.5:1.5b (CPU)."
}

# ---------------------------------------------------------------------------
# 5. Start Ollama service and pull model
# ---------------------------------------------------------------------------
Info "Starting Ollama service..."
Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru | Out-Null
Start-Sleep -Seconds 3

Info "Pulling model: $recommendedModel"
try {
  & ollama pull $recommendedModel
  Ok "Model pulled: $recommendedModel"
} catch {
  Warn "Model pull failed. Run manually: ollama pull $recommendedModel"
}

# Also pull code model if VRAM allows
if ($vramGB -ge 2) {
  Info "Pulling code assistant model: deepseek-coder:1.3b"
  try { & ollama pull deepseek-coder:1.3b; Ok "deepseek-coder:1.3b ready" }
  catch { Warn "deepseek-coder pull failed (non-fatal)" }
}

# ---------------------------------------------------------------------------
# 6. Set up auto-start for Ollama via Task Scheduler
# ---------------------------------------------------------------------------
Info "Setting up Ollama auto-start via Task Scheduler..."
try {
  $action  = New-ScheduledTaskAction -Execute "ollama" -Argument "serve"
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0)
  Register-ScheduledTask -TaskName "OllamaServe-local-ai" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force | Out-Null
  Ok "Task Scheduler entry created"
} catch {
  Warn "Task Scheduler setup failed: $_"
  Warn "Start Ollama manually: ollama serve"
}

# ---------------------------------------------------------------------------
# 7. Network: register hostname with pfsense (instructions)
# ---------------------------------------------------------------------------
Info "Network configuration guidance:"
$hostname = $env:COMPUTERNAME
$ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" }).IPAddress
Info "  Hostname: $hostname"
Info "  IP(s): $($ips -join ', ')"
Info "  MAC addresses:"
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
  Info "    $($_.Name): $($_.MacAddress)"
}
Warn "ACTION REQUIRED:"
Warn "  1. In pfsense: Services > DHCP Server > LAN > Static Mappings"
Warn "  2. Add entry: MAC=$((Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1).MacAddress) IP=192.168.1.3x"
Warn "  3. Update cluster/network-map.yaml on PRIMARY with this IP"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Info "============================================================"
Info "  Windows thin node ready!"
Info ""
Info "  Ollama: http://localhost:11434 (GPU-accelerated if available)"
Info "  Model loaded: $recommendedModel"
Info "  Heavy queries route to PRIMARY via cluster proxy"
Info ""
Info "  To use from CLI:"
Info "    ollama run $recommendedModel"
Info ""
Info "  To point Open WebUI at PRIMARY:"
Info "    Set OPENAI_API_BASE_URL=http://PRIMARY_IP:11434/v1"
Info "============================================================"
