#!/usr/bin/env bash
# Boot the fake monitor + cgminer_manager for screenshot capture.
# Non-interactive: writes PIDs to .run/ and returns once both are ready.

set -euo pipefail

cd "$(dirname "$0")"
repo_root="$(cd ../.. && pwd)"

FAKE_MONITOR_PORT="${FAKE_MONITOR_PORT:-9292}"
MANAGER_PORT="${MANAGER_PORT:-3030}"
FAKE_CGMINER_PORTS=(40281 40282 40283 40284 40285 40286)

for port in "$FAKE_MONITOR_PORT" "$MANAGER_PORT" "${FAKE_CGMINER_PORTS[@]}"; do
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $port is already in use" >&2
    exit 1
  fi
done

mkdir -p .run
rm -f .run/*.pid .run/*.log

start_process() {
  local name="$1"
  shift
  ( "$@" >".run/${name}.log" 2>&1 &
    echo $! >".run/${name}.pid" )
  # Ensure the PID file exists before returning (tiny fork window).
  while [ ! -s ".run/${name}.pid" ]; do sleep 0.05; done
}

wait_until_ready() {
  local name="$1" url="$2" timeout="${3:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  until curl -sf "$url" >/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: $name did not become ready at $url within ${timeout}s" >&2
      echo "--- ${name}.log ---" >&2
      tail -40 ".run/${name}.log" >&2
      exit 1
    fi
    sleep 0.2
  done
}

start_process fake_monitor env PORT="$FAKE_MONITOR_PORT" ruby fake_monitor.rb
wait_until_ready fake_monitor "http://127.0.0.1:${FAKE_MONITOR_PORT}/v2/healthz"

# Fleet of fake cgminer TCP listeners, one per scenario miner. Keeps
# /api/v1/ping.json honest (available? succeeds on real sockets) and
# lets the Admin surface exercise real RPC round-trips.
start_process fake_cgminer_fleet ruby fake_cgminer_fleet.rb
# Probe each port — fake_cgminer speaks raw TCP, not HTTP, so a bash
# `>/dev/tcp/127.0.0.1/PORT` reachability check is the right shape.
for port in "${FAKE_CGMINER_PORTS[@]}"; do
  deadline=$(( $(date +%s) + 30 ))
  until bash -c ">/dev/tcp/127.0.0.1/$port" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: fake cgminer did not bind :$port within 30s" >&2
      tail -40 .run/fake_cgminer_fleet.log >&2
      exit 1
    fi
    sleep 0.2
  done
done

start_process manager env \
  CGMINER_MONITOR_URL="http://127.0.0.1:${FAKE_MONITOR_PORT}" \
  MINERS_FILE="dev/screenshots/miners.yml" \
  SESSION_SECRET="dev-screenshots-not-for-prod-0123456789abcdef0123456789abcdef0123456789abcdef" \
  PORT="$MANAGER_PORT" \
  BIND="127.0.0.1" \
  bash -c "cd '$repo_root' && exec bundle exec bin/cgminer_manager run"

wait_until_ready manager "http://127.0.0.1:${MANAGER_PORT}/" 60

cat <<EOF
Ready.

  Fake cgminer fleet: 127.0.0.1:${FAKE_CGMINER_PORTS[*]}
  Fake monitor:       http://127.0.0.1:${FAKE_MONITOR_PORT}
  cgminer_manager:    http://127.0.0.1:${MANAGER_PORT}/

Logs:   dev/screenshots/.run/{fake_monitor,fake_cgminer_fleet,manager}.log
Tear down with: dev/screenshots/teardown.sh
EOF
