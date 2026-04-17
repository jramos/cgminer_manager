#!/usr/bin/env bash
# Stop anything boot.sh started. Safe to run even if nothing is running.

set -euo pipefail
cd "$(dirname "$0")"

stop_pid() {
  local name="$1"
  local pidfile=".run/${name}.pid"
  [ -f "$pidfile" ] || return 0

  local pid
  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

stop_pid manager
stop_pid fake_monitor

# Belt-and-braces: anything still bound to our known scripts or ports.
pkill -f 'dev/screenshots/fake_monitor.rb' 2>/dev/null || true
for port in "${FAKE_MONITOR_PORT:-9292}" "${MANAGER_PORT:-3030}"; do
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs -I{} kill -TERM {} 2>/dev/null || true
done

echo "Stopped."
