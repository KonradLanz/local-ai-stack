#!/usr/bin/env bash
# =============================================================================
# cluster/start-cluster.sh
# Start all cluster services on PRIMARY node (discovery daemon + proxy).
# License: AGPL-3.0-or-later OR MIT — Copyright 2026 GrEEV.com KG
# =============================================================================
set -euo pipefail
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RESET="\033[0m"
info() { echo -e "${GREEN}[cluster]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}    $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

stop_pid() {
  local pidfile="$1" name="$2"
  if [ -f "$pidfile" ]; then
    PID=$(cat "$pidfile")
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID" && info "Stopped $name (PID $PID)"
    fi
    rm -f "$pidfile"
  fi
}

case "${1:-start}" in
  start)
    info "Starting cluster services..."

    # Discovery daemon
    stop_pid "$REPO_ROOT/.discover.pid" "discover"
    nohup python3 "$SCRIPT_DIR/discover.py" --interval 30 \
      > "$LOG_DIR/discover.log" 2>&1 &
    echo $! > "$REPO_ROOT/.discover.pid"
    info "Discovery daemon started (PID $(cat "$REPO_ROOT/.discover.pid"))"

    # Cluster proxy
    stop_pid "$REPO_ROOT/.proxy.pid" "proxy"
    nohup python3 "$SCRIPT_DIR/proxy.py" \
      > "$LOG_DIR/proxy.log" 2>&1 &
    echo $! > "$REPO_ROOT/.proxy.pid"
    info "Cluster proxy started on :11430 (PID $(cat "$REPO_ROOT/.proxy.pid"))"

    sleep 2
    info "Status check:"
    python3 "$SCRIPT_DIR/discover.py" --once 2>/dev/null | python3 -c \
      "import json,sys; d=json.load(sys.stdin); \
       [print(f'  \u2713 {n[\"name\"]} ({n[\"ip\"]}) — {len(n[\"models\"])} models, {n[\"latency_ms\"]}ms') \
        for n in d['online']]; \
       [print(f'  \u2717 {n[\"name\"]} ({n[\"ip\"]}) — offline') for n in d['offline']]" 2>/dev/null || \
      warn "Status check failed — nodes may still be starting"
    ;;

  stop)
    info "Stopping cluster services..."
    stop_pid "$REPO_ROOT/.discover.pid" "discover"
    stop_pid "$REPO_ROOT/.proxy.pid" "proxy"
    info "Done."
    ;;

  status)
    info "Running discover probe..."
    python3 "$SCRIPT_DIR/discover.py" --once
    ;;

  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
