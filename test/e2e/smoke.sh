#!/usr/bin/env bash
#
# Cross-repo e2e smoke test — assumes the full stack (fake1-3, mongo, monitor,
# manager) is already up and reachable via docker-compose on localhost.
#
# Env inputs:
#   ADMIN_USER, ADMIN_PASSWORD — Basic Auth credentials matching the manager
#   service's CGMINER_MANAGER_ADMIN_USER / CGMINER_MANAGER_ADMIN_PASSWORD.
#
# Exits non-zero on the first failed assertion. Callers (CI, local) are
# responsible for dumping docker-compose logs on failure.

set -euo pipefail

MANAGER="${MANAGER_URL:-http://localhost:13000}"
MONITOR="${MONITOR_URL:-http://localhost:19292}"

: "${ADMIN_USER:?ADMIN_USER must be set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Phase 1: AdminAuth gate is actually engaged -----------------------------
# An unauthenticated POST to an admin route must be rejected. If this passes
# with 200, the admin credentials weren't applied and every subsequent admin
# assertion is meaningless.
echo "== Phase 1: AdminAuth gate =="
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$MANAGER/manager/admin/version")
[[ "$code" == "401" ]] || fail "unauthenticated POST /manager/admin/version returned $code (expected 401)"

# --- Phase 2: monitor contract ----------------------------------------------
echo "== Phase 2: monitor contract =="

# /v2/healthz — poll until status is "healthy" (not "starting", not "degraded").
# Compose's own healthcheck already gates monitor to healthy before manager
# starts, but we re-check here against the external API in case the compose
# gate used a different probe.
status=""
for _ in $(seq 1 30); do
  status=$(curl -sS "$MONITOR/v2/healthz" | jq -r '.status')
  [[ "$status" == "healthy" ]] && break
  sleep 2
done
[[ "$status" == "healthy" ]] || fail "monitor /v2/healthz status=$status (expected healthy)"

# /v2/miners — expect exactly 3 miners, all available.
miners_json=$(curl -sS "$MONITOR/v2/miners")
count=$(echo "$miners_json" | jq '.miners | length')
[[ "$count" == "3" ]] || fail "expected 3 miners, got $count -- $miners_json"
all_avail=$(echo "$miners_json" | jq '[.miners[].available] | all')
[[ "$all_avail" == "true" ]] || fail "not all miners available -- $miners_json"

# --- Phase 3: manager contract ----------------------------------------------
echo "== Phase 3: manager contract =="

# /healthz — manager's own readiness (checks miners.yml + monitor reachable).
health=$(curl -sS "$MANAGER/healthz" | jq -r '.ok')
[[ "$health" == "true" ]] || fail "manager /healthz ok=$health (expected true)"

# Dashboard index must not explode. Content-matching is deliberately avoided
# (HTML escaping, label formatting, and template structure are too volatile
# to assert on); a 200 is enough to catch "MonitorClient contract drifted and
# the view model crashes."
code=$(curl -sS -o /dev/null -w "%{http_code}" "$MANAGER/")
[[ "$code" == "200" ]] || fail "GET / returned $code"

# Miner detail page. The colon in the miner id is URL-encoded because the
# route handler calls CGI.unescape(params[:miner_id]) (http_app.rb).
code=$(curl -sS -o /dev/null -w "%{http_code}" "$MANAGER/miner/fake1%3A4028")
[[ "$code" == "200" ]] || fail "GET /miner/fake1%3A4028 returned $code"

# /api/v1/ping.json — response shape is {timestamp, available_miners,
# unavailable_miners} with integer counts (http_app.rb:699-704).
ping_json=$(curl -sS "$MANAGER/api/v1/ping.json")
avail=$(echo "$ping_json" | jq '.available_miners')
unavail=$(echo "$ping_json" | jq '.unavailable_miners')
[[ "$avail" == "3" && "$unavail" == "0" ]] \
  || fail "ping: available=$avail unavailable=$unavail (expected 3/0) -- $ping_json"

# Admin POSTs — Basic Auth bypasses CSRF (admin_auth.rb), so no token scrape
# needed. Only read-only verbs from ALLOWED_ADMIN_QUERIES are exercised.
for verb in version stats; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -u "$ADMIN_USER:$ADMIN_PASSWORD" \
    -X POST "$MANAGER/manager/admin/$verb")
  [[ "$code" == "200" ]] || fail "POST /manager/admin/$verb returned $code"
done

echo "OK: all smoke assertions passed"
