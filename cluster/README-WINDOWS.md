# Running the Windows Thin Node Setup

**local-ai-stack** — Copyright 2026 GrEEV.com KG

## Why `.\cluster\install-windows-thin.ps1` fails in zsh

The PowerShell script is for **Windows only**. If you see:
```
zsh: command not found: .\cluster\install-windows-thin.ps1
```
you are running this on macOS/Linux. That is expected — run it on
the Windows machine, not the Mac.

---

## How to run on Windows

### Option A — From Windows Explorer
1. Copy the repo to the Windows PC (USB, network share, or `git clone`)
2. Right-click `cluster\install-windows-thin.ps1`
3. Select **Run with PowerShell**
4. If blocked by execution policy, first run in PowerShell:
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

### Option B — From PowerShell (recommended)
```powershell
# 1. Open PowerShell as Administrator
# 2. Navigate to the repo
cd C:\path\to\local-ai-stack

# 3. Allow local scripts (once per machine)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# 4. Run the installer
.\cluster\install-windows-thin.ps1
```

### Option C — From macOS, trigger remotely via SSH
If Windows has OpenSSH server enabled (Settings > Optional Features):
```bash
# From your Mac
ssh user@192.168.1.30 "powershell -ExecutionPolicy Bypass -File C:\\path\\to\\local-ai-stack\\cluster\\install-windows-thin.ps1"
```

---

## What it installs

- Ollama (native Windows binary, GPU-accelerated via CUDA/ROCm if available)
- Small GGUF model sized to your VRAM (`qwen2.5:1.5b` or `phi3.5-mini`)
- Task Scheduler entry to start Ollama at login

## After install

1. Note the MAC address printed at the end
2. Add a pfsense DHCP static mapping for this PC
3. Update `cluster/network-map.yaml` on PRIMARY with the reserved IP
4. Set `enabled: true` for this node in the map
5. On PRIMARY, run: `python3 cluster/discover.py --once` to verify
