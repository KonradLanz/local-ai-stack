#!/usr/bin/env bash
# =============================================================================
# cluster/svc.sh — Service manager for local-ai-stack daemons
# Wraps start/stop/status/restart/logs for discover + proxy.
# Works on macOS (launchd) and Linux (systemd or raw nohup).
#
# Usage:
#   bash cluster/svc.sh start          # start both daemons
#   bash cluster/svc.sh stop           # stop both daemons
#   bash cluster/svc.sh restart        # stop + start
#   bash cluster/svc.sh status         # show PIDs + last log lines
#   bash cluster/svc.sh logs           # tail -f combined log
#   bash cluster/svc.sh logs discover  # tail discover log only
#   bash cluster/svc.sh logs proxy     # tail proxy log only
#   bash cluster/svc.sh install        # register as OS service (auto-start on login)
#   bash cluster/svc.sh uninstall      # remove OS service
#
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

DISCOVER_LOG="$LOG_DIR/discover.log"
PROXY_LOG="$LOG_DIR/proxy.log"
DISCOVER_PID="$REPO_ROOT/.discover.pid"
PROXY_PID="$REPO_ROOT/.proxy.pid"

PYTHON="${PYTHON:-python3}"
# Use venv if present
if [ -x "$REPO_ROOT/.venv/bin/python3" ]; then
  PYTHON="$REPO_ROOT/.venv/bin/python3"
fi

# ANSI
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; DIM="\033[2m"; RESET="\033[0m"
info()  { echo -e "${GREEN}[svc]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[svc]${RESET}  $*"; }
err()   { echo -e "${RED}[svc]${RESET}  $*" >&2; }

# ---------------------------------------------------------------------------
# PID helpers
# ---------------------------------------------------------------------------

pid_running() {
  local pidfile="$1"
  [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

stop_pid() {
  local pidfile="$1" name="$2"
  if pid_running "$pidfile"; then
    local pid; pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null && info "Stopped $name (PID $pid)"
    # Wait up to 3s for clean exit
    for i in 1 2 3; do kill -0 "$pid" 2>/dev/null && sleep 1 || break; done
    kill -9 "$pid" 2>/dev/null || true
  else
    info "$name not running"
  fi
  rm -f "$pidfile"
}

start_daemon() {
  local name="$1" script="$2" logfile="$3" pidfile="$4"
  shift 4
  stop_pid "$pidfile" "$name"   # kill stale instance if any
  # Rotate log if > 5MB
  if [ -f "$logfile" ] && [ "$(wc -c < "$logfile")" -gt 5242880 ]; then
    mv "$logfile" "${logfile%.log}-$(date +%Y%m%d-%H%M%S).log"
    info "Rotated $name log"
  fi
  nohup "$PYTHON" "$script" "$@" >> "$logfile" 2>&1 &
  echo $! > "$pidfile"
  info "Started $name (PID $(cat "$pidfile")) → $logfile"
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------

OS="$(uname -s)"

# ---------------------------------------------------------------------------
# macOS LaunchAgent
# ---------------------------------------------------------------------------

LAUNCH_AGENT_LABEL="com.greev.local-ai-stack"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

install_macos() {
  cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>$(which bash)</string>
    <string>${SCRIPT_DIR}/svc.sh</string>
    <string>start</string>
  </array>

  <!-- Start on login, restart if it crashes -->
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>

  <!-- stdout/stderr go to log files directly -->
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-svc.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-svc.log</string>

  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>DISCOVER_INTERVAL</key>
    <string>30</string>
  </dict>
</dict>
</plist>
PLIST

  # Unload old registration if present (ignore errors)
  launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
  info "Installed LaunchAgent: $LAUNCH_AGENT_PLIST"
  info "Service will auto-start on next login."
  info "To start now: launchctl kickstart gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
}

uninstall_macos() {
  launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT_PLIST"
  info "Removed LaunchAgent."
}

# ---------------------------------------------------------------------------
# Linux systemd user service
# ---------------------------------------------------------------------------

SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_UNIT="local-ai-stack.service"

install_linux() {
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat > "$SYSTEMD_UNIT_DIR/$SYSTEMD_UNIT" << UNIT
[Unit]
Description=local-ai-stack discovery + proxy daemons
After=network-online.target

[Service]
Type=forking
WorkingDirectory=${REPO_ROOT}
ExecStart=$(which bash) ${SCRIPT_DIR}/svc.sh start
ExecStop=$(which bash) ${SCRIPT_DIR}/svc.sh stop
Restart=on-failure
RestartSec=10
Environment=DISCOVER_INTERVAL=30

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable "$SYSTEMD_UNIT"
  info "Installed systemd user service: $SYSTEMD_UNIT"
  info "Start now: systemctl --user start $SYSTEMD_UNIT"
  info "Status:    systemctl --user status $SYSTEMD_UNIT"
}

uninstall_linux() {
  systemctl --user stop "$SYSTEMD_UNIT" 2>/dev/null || true
  systemctl --user disable "$SYSTEMD_UNIT" 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT_DIR/$SYSTEMD_UNIT"
  systemctl --user daemon-reload
  info "Removed systemd user service."
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
  info "Starting local-ai-stack daemons..."
  start_daemon "discover" "$SCRIPT_DIR/discover.py" "$DISCOVER_LOG" "$DISCOVER_PID" \
    --interval 30
  start_daemon "proxy" "$SCRIPT_DIR/proxy.py" "$PROXY_LOG" "$PROXY_PID"
  sleep 1
  cmd_status
}

cmd_stop() {
  info "Stopping local-ai-stack daemons..."
  stop_pid "$DISCOVER_PID" "discover"
  stop_pid "$PROXY_PID" "proxy"
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  echo
  echo -e "  ${GREEN}discover${RESET}  "\
    "$(pid_running "$DISCOVER_PID" && echo -e "${GREEN}running$(cat "$DISCOVER_PID")${RESET}" || echo -e "${RED}stopped${RESET}")"
  echo -e "  ${GREEN}proxy${RESET}     "\
    "$(pid_running "$PROXY_PID" && echo -e "${GREEN}running (PID $(cat "$PROXY_PID"))${RESET}" || echo -e "${RED}stopped${RESET}")"
  echo
  echo -e "  ${DIM}Discover log: $DISCOVER_LOG${RESET}"
  echo -e "  ${DIM}Proxy log:    $PROXY_LOG${RESET}"
  echo
  if [ -f "$DISCOVER_LOG" ]; then
    echo -e "  ${DIM}-- last 5 discover lines --${RESET}"
    tail -n 5 "$DISCOVER_LOG" | sed 's/^/  /'
  fi
  echo
}

cmd_logs() {
  local target="${1:-all}"
  case "$target" in
    discover) tail -f "$DISCOVER_LOG" ;;
    proxy)    tail -f "$PROXY_LOG" ;;
    *)
      # Interleave both logs with colour prefix
      if command -v multitail &>/dev/null; then
        multitail -ci green "$DISCOVER_LOG" -ci yellow "$PROXY_LOG"
      else
        # Plain tail on both
        tail -f "$DISCOVER_LOG" "$PROXY_LOG"
      fi
      ;;
  esac
}

cmd_install() {
  case "$OS" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
}

cmd_uninstall() {
  case "$OS" in
    Darwin) uninstall_macos ;;
    Linux)  uninstall_linux ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Kill any orphaned discover.py not owned by our PID file
# ---------------------------------------------------------------------------
cmd_kill_orphans() {
  local our_pid=""
  [ -f "$DISCOVER_PID" ] && our_pid=$(cat "$DISCOVER_PID")
  pgrep -f "discover\.py" | while read -r pid; do
    if [ "$pid" != "$our_pid" ]; then
      warn "Killing orphaned discover.py PID $pid"
      kill "$pid" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-help}" in
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs "${2:-all}" ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  kill-orphans) cmd_kill_orphans ;;
  help|--help|-h)
    echo "Usage: bash cluster/svc.sh {start|stop|restart|status|logs [discover|proxy]|install|uninstall|kill-orphans}"
    ;;
  *)
    err "Unknown command: ${1}"
    echo "Usage: bash cluster/svc.sh {start|stop|restart|status|logs|install|uninstall}"
    exit 1
    ;;
esac
