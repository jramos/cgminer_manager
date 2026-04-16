# cgminer_manager Modernization — Design

- **Date:** 2026-04-16
- **Status:** Draft, awaiting user review
- **Target version:** 1.0.0

## 1. Context

`cgminer_manager` is the third leg of a three-repo Ruby stack for operating cgminer rigs:

1. `cgminer_api_client` — low-level Ruby wrapper around cgminer's JSON-over-TCP API.
2. `cgminer_monitor` — background poller + MongoDB time-series store + HTTP API exposing miner samples and snapshots.
3. `cgminer_manager` — web UI for humans: dashboard, per-miner pages, and pool management controls (add/disable/remove pool, save).

The first two have recently been modernized. `cgminer_api_client` 0.3.0 introduced breaking changes (`PoolResult`/`MinerResult` value objects, explicit error hierarchy). `cgminer_monitor` was rewritten from a Rails engine into a standalone Sinatra service, replaced its STI-based document hierarchy with two collections (time-series `samples` + upserted `latest_snapshot`), and ships `MIGRATION.md` instructing `cgminer_manager` to drop its direct Mongo reads and consume monitor's `/v2/*` HTTP API instead.

`cgminer_manager` currently sits on Rails 4.2.11, Mongoid 4.0 (moped driver), Thin, therubyracer, no `.ruby-version`, no tests, no CI. It reads Mongo directly via `CgminerMonitor::Document::Summary.constantize.last_entry` — a path that no longer exists in modernized monitor. It is broken against the current stack.

## 2. Goals

- Bring `cgminer_manager` onto the same Ruby and tooling baseline as the other two repos.
- Unblock it from the `cgminer_api_client` 0.3.0 and modernized `cgminer_monitor` breaking changes.
- Preserve the existing user-visible UX (HAML pages, Chart.js graphs, audio alerts, polling refresh, pool-management forms).
- Replace the silently-failing pool-management code path with something observably correct.
- Establish a real test suite, CI, and Docker packaging on par with `cgminer_monitor`.

## 3. Non-goals

- Redesigning the UI. The existing HAML pages and JS stay functionally the same.
- Adding authentication. The service keeps its "localhost / trusted network only" posture.
- Introducing a new data store. Manager owns no state.
- Migrating to Rails 7/8. Framework shape changes (see § 4).
- Adding features beyond what exists today. Notable feature **removal**: the current `POST /manager/run` and `POST /miner/:id/run` arbitrary-command endpoints are cut in 1.0.0 (see § 7.1, § 17).
- Scaling beyond ~20 miners per deployment. Realistic target audience is home/small-shop operators; larger farms use vendor tooling. The fan-out strategy in § 6.1 is tuned for that scale and degrades gracefully (slower page, no timeout) above it. If real demand for more appears, the remedy is progressive per-tile rendering, not a rearchitecture.
- Prometheus / metrics export. Structured logs (§ 12) + `/healthz` (§ 6.5) are the observability surface for 1.0.0.

## 4. Architecture

### 4.1 Shape

`cgminer_manager` becomes a standalone Sinatra + Puma service, structurally a sibling of modernized `cgminer_monitor`. One process, one CLI entry point, no Rails.

**Owns:**

- UI rendering (dashboard, per-miner pages, pool-management forms).
- Pool-management commands against cgminers via `cgminer_api_client` 0.3.x.
- A tiny compatibility endpoint, `GET /api/v1/ping.json`.

**Does not own:**

- Any MongoDB connection. Mongoid, moped, and the `mongo` gem are all removed.
- Any knowledge of monitor's storage schema.
- Any time-series data.

### 4.2 External dependencies at runtime

- **cgminers** — command plane only. Socket JSON via `cgminer_api_client::Miner` / `MinerPool`.
- **cgminer_monitor** — read plane only. HTTP JSON against `/v2/*` via a new `CgminerMonitorClient`.

### 4.3 Rationale for shape

- A ~500 LOC web app does not warrant Rails. Sinatra + Puma is the right size and matches the sister project's skeleton.
- Dropping the direct Mongo read path turns a broken integration into a cleanly-bounded HTTP dependency. Manager no longer needs to know what storage monitor uses.
- Incremental Rails upgrade (4 → 5 → 6 → 7) would cost more than a full Sinatra port for a codebase this small and this under-tested.

### 4.4 Miner identity

Miners are identified end-to-end by **`"host:port"`** strings (matching monitor's internal key). This replaces the current Rails app's integer-array-index scheme (`/miner/0` = `miners.yml[0]`), which silently corrupted bookmarks on `miners.yml` reorder.

- In-memory, URLs, logs: `"10.0.0.5:4028"`.
- In URLs: CGI-encoded — `/miner/10.0.0.5%3A4028`. The route is declared `get '/miner/:miner_id' do ... end`; Sinatra URL-decodes the param.
- `bin/cgminer_manager doctor` verifies every `miners.yml` entry resolves in `GET /v2/miners` so typos surface immediately rather than as silently-dead bookmarks.
- **MIGRATION note** (tracked in § 17): old integer URLs (`/miner/0`) stop working. Documented one-time break.

## 5. Component layout

```
cgminer_manager/
├── bin/cgminer_manager              # CLI: run | doctor | version
├── lib/cgminer_manager/
│   ├── version.rb
│   ├── errors.rb                    # Error / ConfigError / MonitorError hierarchy
│   ├── config.rb                    # Data.define value object, from_env
│   ├── logger.rb                    # JSON/text, thread-safe (port of monitor's)
│   ├── monitor_client.rb            # HTTP client for monitor /v2/*
│   ├── pool_manager.rb              # service object for add/disable/remove/save
│   ├── http_app.rb                  # Sinatra::Base subclass; routes + view helpers
│   ├── server.rb                    # Puma launcher + signal handling + graceful stop
│   └── cli.rb                       # verb dispatcher for bin/cgminer_manager
├── views/                           # HAML, ported from app/views
│   ├── layouts/application.haml
│   ├── manager/…
│   └── miner/…
├── public/                          # static JS/CSS/fonts/audio (no Sprockets)
│   ├── js/{chart.min.js, manager.js, miner.js, audio.js, graph.js, config.js, jquery.min.js}
│   ├── css/application.css
│   └── audio/
├── config/
│   ├── miners.yml.example           # unchanged shape (command-plane whitelist)
│   └── puma.rb
├── spec/
│   ├── cgminer_manager/             # unit specs per lib/ file
│   ├── integration/                 # FakeCgminer + WebMock-stubbed monitor + Rack::Test
│   └── support/{fake_cgminer.rb, cgminer_fixtures.rb, monitor_stubs.rb}
├── Dockerfile                       # multi-stage
├── docker-compose.yml               # manager + monitor + mongo for local dev
├── .github/workflows/ci.yml         # lint / test matrix / integration
├── .rubocop.yml
├── .ruby-version                    # 4.0.2
├── Gemfile
├── cgminer_manager.gemspec          # required_ruby_version >= 3.2
├── Rakefile
├── README.md
├── MIGRATION.md                     # Rails→Sinatra notes for existing operators
└── CHANGELOG.md
```

One responsibility per file:

- `config.rb`, `logger.rb`, `errors.rb` mirror monitor's shape where possible — deliberate consistency between sister projects.
- `monitor_client.rb` is the one place that knows monitor's HTTP shape; callers deal in plain hashes.
- `pool_manager.rb` is the one place that orchestrates `cgminer_api_client` management commands and their bounded verification step.
- `http_app.rb` is the Sinatra app — routes, view bindings, error rendering; no business logic.
- `server.rb` is Puma lifecycle + signal handling; no HTTP route logic.
- `cli.rb` is a thin verb dispatcher.

## 6. Data flow

### 6.1 Read path (dashboard, per-miner pages)

```
Browser ──GET /──▶ Sinatra::HttpApp
                      │
                      ├─ MonitorClient#miners                  ──HTTP──▶ monitor /v2/miners
                      ├─ MonitorClient#summary(miner_id) etc.  ──HTTP──▶ monitor /v2/miners/:miner/summary
                      └─ HAML rendering with plain hashes
```

- Controller action builds a view model (list of miners, each with latest summary/devices/pools/stats) and passes it to HAML.
- `MonitorClient` issues `/v2/miners/:miner/*` calls in parallel across miners via a bounded thread pool (cap ~8). Per-call timeout 2s. Page-total budget ~5s for the ~20-miner target scale (§ 3).
- Monitor's per-miner responses include a `fetched_at` timestamp and an `ok` field. Three render states per tile:
  - **Healthy** — `response` present, `fetched_at` within `STALE_THRESHOLD_SECONDS` (§ 10, default 300s): normal render.
  - **Stale** — `response` present but `fetched_at` older than the threshold: render normally with a "updated Xm ago" warning badge. Operators can see that the dashboard isn't lying about live state.
  - **Waiting for first poll** — `response.nil? && error.nil?` (monitor knows the miner but hasn't polled yet): render the tile with em-dashes and a "waiting for first poll" placeholder. Avoids the `NoMethodError`-on-200 path at fresh boot.
- On monitor unavailable at the HTTP level: `MonitorError` raised by client, caught in controller, dashboard shell renders with a "data source unavailable" banner. No 500.
- Rationale: splitting manager from monitor's data plane is pointless if a monitor outage takes the command plane down too.

### 6.2 Graph data path (per-miner graphs)

```
Browser JS ──GET /miner/:miner_id/graph_data/:metric?since=…──▶ Sinatra
                                                              │
                                                              └─ MonitorClient#graph_data ──▶ monitor /v2/graph_data/:metric?miner=:id&since=…
                                                                                           ◀── {fields:[...], data:[[...]]}
                                                              │
                                                              └─ reshape to [[ts, v1, v2, ...], ...] for Chart.js
```

Manager's `/miner/:miner_id/graph_data/:metric` is **not** a literal pass-through. Monitor returns a structured `{fields:[...], data:[[...]]}` envelope (`cgminer_monitor/lib/cgminer_monitor/http_app.rb:108+`); the existing browser `graph.js` expects bare `[[ts, v1, v2, ...]]` arrays. Manager's endpoint reshapes: drops the `fields` header and yields the rows. The reshape is exercised by `graph_data_spec.rb` against real monitor fixtures (see § 15).

**Metrics coverage is preserved in full.** Monitor today exposes three metrics (`hashrate`, `temperature`, `availability`). The current UI renders additional diagnostic graphs (hardware error, pool stale/rejected, device rejected, and a local/miner split) — these are operator-critical when something is wrong. The remedy is a **companion PR against `cgminer_monitor`** that adds the missing `/v2/graph_data/:metric` endpoints, which must land before manager 1.0.0. Rationale: the same engineer owns both repos; dropping diagnostic graphs for the life of 1.0.x is a permanent UX regression; the monitor PR is small (monitor's existing three endpoints share structure — see http_app.rb:108,127,145). Manager 1.0.0's gemspec declares a minimum monitor release via README (there is no gem-level linkage since the dependency is HTTP, not Ruby).

### 6.3 Command path (pool management)

```
Browser ──POST /manager/manage_pools──▶ Sinatra
                                          │
                                          └─ PoolManager#disable_pool(miner_ids, url)
                                                │
                                                ├─ miners loaded from miners.yml (keyed by "host:port")
                                                ├─ for each miner in bounded thread pool:
                                                │     CgminerApiClient::Miner#{disablepool|removepool|enablepool|addpool}
                                                │     for disable/remove/enable: one :pools re-query (~2s socket timeout)
                                                │         → state-matched ?  :ok  :  :indeterminate
                                                │     for addpool: no re-query — api_client's ApiError on STATUS=E/F
                                                │         is already the success signal
                                                │     CgminerApiClient::Miner#query(:save) — recorded as its own entry
                                                └─ returns PoolActionResult (per-miner + per-step status)
                                          │
                                          └─ render response with per-miner outcome
```

- No unbounded `while` loop; no unconditional `sleep(5)`. A single bounded socket-timeout verification query for state-changing commands. We never hang.
- Rescues narrowed to `CgminerApiClient::ConnectionError` / `TimeoutError` / `ApiError`. `StandardError` is not caught.
- Partial success (e.g., 3 of 5 miners accepted the command) is a first-class render state. See § 7 for `PoolActionResult`'s three-state shape.

### 6.4 Compatibility endpoint

```
Probe ──GET /api/v1/ping.json──▶ Sinatra
                                   │
                                   └─ CgminerApiClient::MinerPool
                                        .available_miners.count / .unavailable_miners.count
                                                │
                                                ▼
                                   { timestamp: <epoch_s>,
                                     available_miners:   <int>,
                                     unavailable_miners: <int> }
```

Preserves the existing JSON shape and data source verbatim from `app/controllers/api/v1/ping_controller.rb`. **Computed from cgminers directly via `cgminer_api_client`**, not via monitor — a monitor outage must not cause the probe to go red, since that would violate the § 6.1 invariant that the command plane stays usable when the read plane is degraded.

### 6.5 Health endpoint

```
Probe ──GET /healthz──▶ Sinatra
                          │
                          ├─ load miners.yml → ok if parses
                          └─ GET $CGMINER_MONITOR_URL/v2/healthz (1s timeout)
                                → 200: ok
                                → anything else: degraded
```

- 200 `{ok: true}` when both checks pass.
- 503 `{ok: false, reasons: [...]}` when any fails (miners.yml unparseable, monitor unreachable, monitor returns non-2xx).
- No database, no deep checks, no Prometheus format. Plain JSON suitable for load balancer / uptime probes.
- Separate from `/api/v1/ping.json` — `/healthz` reports service health (this process + its dependency); `/api/v1/ping.json` preserves the existing cgminer-reachability probe.

## 7. Pool-management rewrite (PoolManager)

The current `app/helpers/miner_helper.rb` is the single worst piece of code in the app. For each pool-management action it:

1. `Thread.new` per miner.
2. `sleep(5)` unconditionally.
3. Polls `@miner.query(:pools)` in an unbounded loop waiting for state convergence.
4. Rescues bare `Exception` and silently logs.
5. Calls `@miner.query(:save)`.

### 7.1 Scope: what's kept, what's cut

**Kept** (modernized with narrow rescues and typed results):
- `add_pool(miners, url, user, pass)`
- `disable_pool(miners, pool_index)`
- `enable_pool(miners, pool_index)`
- `remove_pool(miners, pool_index)`
- `save(miners)` — persist config to disk (exposed as its own step in `PoolActionResult`; see below).

**Cut in 1.0.0**: the Rails app's arbitrary-command endpoints (`POST /manager/run`, `POST /miner/:id/run`) that let the UI execute any cgminer verb. Reasons:
1. Security blast radius. An unauthenticated arbitrary-command surface against mining hardware is a very bad day if manager is ever exposed beyond localhost (e.g., misconfigured reverse proxy). The typed API above covers actual real-world use; the escape hatch is a liability.
2. `rescue StandardError` around arbitrary user input violates § 8's "no silent swallow" rule and cannot be narrowed without losing the "anything goes" semantics.
3. Operators who genuinely need raw command access have `cgminer_api_client` in IRB.

MIGRATION.md calls out the removal with the IRB alternative. If post-release demand shows the cut was wrong, the follow-up is a narrow **allow-list** of side-effect-free commands (`version`, `check`, `summary`) — not a re-opened arbitrary executor.

### 7.2 Implementation shape

`lib/cgminer_manager/pool_manager.rb`:

- One public method per action (§ 7.1), each returning a `PoolActionResult`.
- Execution uses a bounded thread pool (size matches miner count up to a small cap, e.g., 8).
- Rescues: only `CgminerApiClient::ConnectionError`, `CgminerApiClient::TimeoutError`, `CgminerApiClient::ApiError`. Other exceptions propagate.

### 7.3 Verification semantics

| Command        | Verification after the call | Rationale                                                                 |
|----------------|-----------------------------|---------------------------------------------------------------------------|
| `add_pool`     | **None.** Trust STATUS=S.   | cgminer doesn't always reflect a new pool in `:pools` within 2s; a one-shot re-query reports most successful adds as "did not converge" and erodes operator trust. `cgminer_api_client` already raises `ApiError` on STATUS=E/F — success is an already-reliable signal. |
| `disable_pool` | One `:pools` re-query.      | State flips fast; operators want visible confirmation.                    |
| `enable_pool`  | One `:pools` re-query.      | Same as disable.                                                          |
| `remove_pool`  | One `:pools` re-query.      | Same.                                                                     |
| `save`         | None.                       | cgminer's `save` returns STATUS=S on persisted-to-disk success.           |

Verification queries use the socket-level timeout from `cgminer_api_client` (~2s). We never loop.

### 7.4 `PoolActionResult` — three-state

Two-state (`:ok` / `:failed`) conflated three operationally different outcomes. `PoolActionResult` carries per-miner, per-step entries:

```
PoolActionResult
  ├─ entries: [MinerEntry, ...]
  └─ MinerEntry
       ├─ miner: "host:port"
       ├─ command_status:  :ok | :failed | :indeterminate
       ├─ command_reason:  Exception | nil
       ├─ save_status:     :ok | :failed | :indeterminate | :skipped
       └─ save_reason:     Exception | nil
```

Status meanings:

- `:ok` — cgminer returned STATUS=S and (when applicable) verification observed the expected state.
- `:failed` — cgminer returned STATUS=E/F (`ApiError`), or the TCP connection failed before the command acked. The action did not happen.
- `:indeterminate` — command was sent and ack'd, but verification failed to observe the expected state or the verification query itself timed out. The command probably applied; we can't confirm. UI renders this as a warning, not an error.
- `save_status = :skipped` — the action itself failed, so `save` was not attempted.

`save` is tracked as a separate step because "did the config actually persist?" is operationally distinct from "did the pool command apply in memory?" — operators need to know if a reboot would revert their change.

The controller renders `PoolActionResult` to a per-miner summary table: ✓ / ✗ / ⚠ with reason.

## 8. Error handling

Three error domains, each with its own behavior.

**Configuration errors** — `CgminerManager::ConfigError`
- Raised during `Config.from_env` / miners.yml loading.
- Caught at CLI boot only. `bin/cgminer_manager run` exits non-zero with a single-line stderr message.
- Never reached by request-handling code.

**Read-plane errors** — `CgminerManager::MonitorError` hierarchy
- `MonitorError::ConnectionError` (transport) and `MonitorError::ApiError` (monitor returned non-2xx).
- Raised only by `MonitorClient`.
- Caught in `http_app.rb` at controller-action boundary. Rendered as a banner + partial data (§ 6.1).
- Logged at `warn` with `{ url, status, duration_ms }`. Monitor outage is degraded-but-expected state, not a bug.

**Command-plane errors** — re-exposed from `cgminer_api_client`
- `CgminerApiClient::ConnectionError` / `TimeoutError` / `ApiError` propagate through `PoolManager`.
- `PoolManager` does not rescue them at the top level — it catches per-miner inside the thread pool, writes the per-miner entry, and returns the `PoolActionResult`.
- Controller renders outcomes. Partial success is normal.

**Uncaught `StandardError`** is a bug.
- Sinatra dev: default error page. Production: generic 500 with an incident id.
- Logged at `error` with full backtrace.
- Never rescued inside business logic. This is the explicit replacement for `rescue Exception` in `miner_helper.rb:20,37`.

**No `Timeout.timeout`.** All timeouts are socket-level: `cgminer_api_client`'s built-in timeout parameter, and the `http` gem's per-request `.timeout(2)` for monitor calls.

**No silent `sleep` in production code.** The only use of a wait primitive is the interruptible condition-variable wait in `server.rb` for graceful shutdown.

## 9. HTTP client for cgminer_monitor

- **Library:** `http` gem. Small, modern, ergonomic for JSON + timeouts; no middleware machinery needed for a localhost call.
- **Shape:** `CgminerMonitorClient` with methods returning plain hashes parsed from JSON:
  - `#miners` → `GET /v2/miners` — array of miner descriptors.
  - `#summary(miner_id)` → `GET /v2/miners/:miner/summary`.
  - `#devices(miner_id)` → `GET /v2/miners/:miner/devices`. (Note: endpoint is `devices`, not `devs`; cgminer's raw JSON key `DEVS` is exposed as `devices` in monitor — see `cgminer_monitor/lib/cgminer_monitor/http_app.rb:90`.)
  - `#pools(miner_id)` → `GET /v2/miners/:miner/pools`.
  - `#stats(miner_id)` → `GET /v2/miners/:miner/stats`.
  - `#graph_data(metric:, miner_id:, since:)` → `GET /v2/graph_data/:metric` — returns `{fields:[...], data:[[...]]}`; client returns as-is and the reshape happens in the Sinatra graph endpoint (§ 6.2).
- **Config:** `CGMINER_MONITOR_URL` env var pointing at a running monitor (default host/port per monitor's README).
- **Miners list:** `config/miners.yml` stays. It is the command-plane whitelist — the set of hosts this service is allowed to send cgminer commands to — and is independent of whatever monitor knows.
- **No `mongoid.yml`.** Removed from the repo.
- **Timeouts:** 2s per call. No retry.
- **Typed value objects over the wire:** not for v1. Plain hashes. Add wrappers later if any call site gets messy.
- **Thread safety.** `HTTP::Client` instances in the `http` gem are **not** thread-safe across threads (internal connection state mutates). Two acceptable patterns: (a) shorthand `HTTP.get(url, …)` per call — safe but no keep-alive, one TCP connect per call; (b) one persistent client per thread via a `ThreadLocal` / `Thread.current[:monitor_client]`, which retains keep-alive. Default to (a) for simplicity in v1; revisit if profiling shows the extra handshakes matter. Spec note so the implementer does not accidentally share a single `HTTP::Client` across the `MonitorClient` thread pool.

## 10. Configuration

- `CGMINER_MONITOR_URL` — required. Base URL for monitor.
- `MINERS_FILE` — default `config/miners.yml`.
- `PORT` — default `3000` (preserves current behavior).
- `BIND` — default `127.0.0.1` (preserves "local network only" posture).
- `LOG_FORMAT` — `json` or `text`, default `text` in dev, `json` in prod.
- `LOG_LEVEL` — default `info`.
- `SESSION_SECRET` — required in production. Used to sign Sinatra's cookie-based sessions (which carry the CSRF token; see § 13). In development, falls back to a generated random value with a loud warning; in production, boot fails with `ConfigError` if unset.
- `STALE_THRESHOLD_SECONDS` — default `300`. Age of monitor's `fetched_at` beyond which the per-miner tile renders a "stale" warning (§ 6.1). Operators on unusually long poll intervals can raise it.

Loaded into a `Config` value object via `Data.define`, mirroring `cgminer_monitor/lib/cgminer_monitor/config.rb`.

## 11. CLI

`bin/cgminer_manager` dispatches:

- `run` — start Puma + Sinatra. Install SIGTERM/SIGINT handlers. Graceful shutdown.
- `doctor` — operator-facing health probe, exit 0 if all checks pass, non-zero otherwise. Checks:
  1. `miners.yml` parses and all entries have `host`/`port`.
  2. For each miner, `CgminerApiClient::Miner#available?` — cgminer reachable.
  3. `GET $CGMINER_MONITOR_URL/v2/miners` returns 200 and parseable JSON. Failure here means monitor is pre-v2 (upgrade monitor first — see § 17) or unreachable.
  4. Every `miners.yml` entry resolves to a miner in monitor's `/v2/miners` response. Catches typos (`host:port` mismatch between manager and monitor) before they produce silently-dead dashboard bookmarks.
- `version` — print `CgminerManager::VERSION`.

No `migrate` verb (no schema).

## 12. Logging

- Module-level (`CgminerManager::Logger`) with class methods `info`, `warn`, `error`, `debug`.
- Dual format: JSON (default in prod) and human-readable text (default in dev).
- Level filtering via `LOG_LEVEL`.
- Thread-safe. Direct port of monitor's logger.
- **Structured per-call timing log** inside `MonitorClient` — one `info` line per HTTP call with `{url, method, status, duration_ms}`. Zero-ceremony observability: when the dashboard is slow, operators can tell whether it's manager's render or monitor's response without attaching a profiler. Manager's own per-page render time is logged at the controller layer: `{path, render_ms, monitor_calls, monitor_errors}`.

## 13. Authentication and security posture

- No auth added. Default bind stays at `127.0.0.1`. Operators who expose the service on a network do so via a reverse proxy they control.
- CSRF transport specified (the current Rails `authenticity_token` model does not survive the framework change, and the pool-management forms submit via jQuery XHR — `remote: true` in the Rails views — not full-page POSTs):
  - Layout emits `<meta name="csrf-token" content="<%= csrf_token %>">`.
  - `rack-protection`'s `AuthenticityToken` middleware enforces the token on state-changing methods (POST/PUT/PATCH/DELETE). Token read from either the `authenticity_token` form field (full-page fallback) or the `X-CSRF-Token` header (XHR path).
  - `public/js/manager.js` and `public/js/miner.js` install a global jQuery `$.ajaxSetup` `beforeSend` that reads the meta tag and sets the `X-CSRF-Token` header on every XHR. This keeps the existing `remote: true`-style flows working without per-form plumbing.
  - Tokens are carried in Sinatra's cookie-based sessions (signed, client-side — no server-side state, consistent with § 4 "manager owns no state"). Session secret per § 10.
- Integration spec `pool_management_spec.rb` (§ 15.2) includes a case that POSTs without a token and asserts 403, so a regression can't silently disable CSRF protection.

## 14. UI preservation

- HAML templates from `app/views/**/*.haml` port to `views/**/*.haml` with Rails helper calls swapped for Sinatra equivalents (`link_to` becomes either Sinatra `url` helper or a small local helper; `form_for` becomes an explicit `<form>` tag with the CSRF token inlined).
- `app/assets/javascripts/{chart.min.js, manager.js, miner.js, audio.js, graph.js, config.js, jquery.min.js}` move to `public/js/` verbatim.
- `app/assets/stylesheets/*.css` move to `public/css/`.
- Sprockets, therubyracer, jquery-rails, sass-rails, coffee-rails — all removed.
- Layout references assets by explicit `<script src="/js/…">` / `<link href="/css/…">` tags.
- No bundler, no transpile step.
- **Chart.js version is pinned as-is.** The checked-in `chart.min.js` is a legacy 1.x whose API (`new Chart(ctx).Line(...)`) the existing `graph.js` depends on. No Chart.js upgrade in v1 — a "modernization" of this one file will break every graph. If upgrading, the graph JS needs to be rewritten in the same PR.
- **Audio alert data source.** `audio.js` triggers thresholds off the same dashboard view model that the HAML layer receives (i.e., from `MonitorClient` responses). The Sinatra layout passes a minimal JSON payload (miners + availability) into a `<script>` tag on the dashboard, same pattern as the Rails version — no new endpoint needed.

## 15. Testing strategy

Three layers.

### 15.1 Unit (`spec/cgminer_manager/`) — one file per `lib/` file

- `config_spec.rb` — env parsing, miners.yml loading, validation errors.
- `logger_spec.rb` — JSON vs text format, level filtering, thread-safety smoke.
- `errors_spec.rb` — hierarchy shape.
- `monitor_client_spec.rb` — WebMock-stubbed responses; one test per endpoint for happy path, one for 5xx → `MonitorError::ApiError`, one for connection refused → `MonitorError::ConnectionError`, one for timeout.
- `pool_manager_spec.rb` — `CgminerApiClient::Miner` stubbed via `instance_double`; covers add/disable/remove/enable/save, per-miner partial success, bounded verification timeout → `:indeterminate`, ApiError → `:failed`, ConnectionError before command → `:failed` with `save_status: :skipped`, addpool success without verification, save-as-separate-step.
- `cli_spec.rb` — `Open3`-driven end-to-end for `run` (boot + graceful shutdown), `doctor`, `version`, unknown verb.

### 15.2 Integration (`spec/integration/`) — real Sinatra app, real `cgminer_api_client`, stubbed externals

- `dashboard_spec.rb` — `Rack::Test` drives `GET /`. Monitor stubbed via WebMock. Two variants: all monitor calls succeed; all monitor calls fail (banner appears, no 500).
- `miner_page_spec.rb` — `Rack::Test` drives `GET /miner/:id`. Same pattern.
- `graph_data_spec.rb` — verifies pass-through shape matches what `graph.js` expects.
- `pool_management_spec.rb` — `Rack::Test` drives `POST /manager/manage_pools` and `POST /miner/:miner_id/manage_pools`. Command plane uses **real** `cgminer_api_client` against `FakeCgminer` (ported from api_client's `spec/support/fake_cgminer.rb`) to exercise the real socket and PoolResult unwrap. Covers: all-ok (with one success `:ok` and one `:indeterminate`), one-miner-down (ConnectionError → `:failed`), ApiError from cgminer (→ `:failed`), verification timeout (→ `:indeterminate`), addpool path with no verification, `save` as separate result entry.
- `ping_spec.rb` — `/api/v1/ping.json` shape preservation; asserts data comes from cgminer path (not monitor) by stubbing monitor as 5xx and expecting a green ping.
- `healthz_spec.rb` — `/healthz` returns 200 when monitor healthy, 503 with `reasons` when monitor is unreachable or miners.yml is unparseable.
- `staleness_spec.rb` — dashboard tile renders "updated Xm ago" warning when `fetched_at` is older than `STALE_THRESHOLD_SECONDS`; normal render otherwise; "waiting for first poll" placeholder when response is nil and no error.
- `full_boot_spec.rb` — boot real `Server` against FakeCgminer + WebMock-stubbed monitor, issue one HTTP request via `Rack::Test`, stop gracefully. Mirrors monitor's `full_pipeline_spec.rb`. Catches "I broke the wiring."

### 15.3 Fixtures

- Port `FakeCgminer` and `cgminer_fixtures.rb` from `cgminer_api_client/spec/support/`.
- Add `monitor_stubs.rb` with helpers (`stub_monitor_miners`, `stub_monitor_summary`, etc.) wrapping WebMock.
- Monitor response fixture JSON under `spec/fixtures/monitor/`. **Generate once against a real running monitor** (a small `rake spec:refresh_monitor_fixtures` task captures current `/v2/*` responses) rather than hand-rolling JSON — hand-rolled fixtures drift from reality. Check the generator task and the captured JSON in; regenerate when monitor's response shape changes.
- **FakeCgminer connection model.** `FakeCgminer` accepts one request per connection, then closes the socket (see `cgminer_api_client/spec/support/fake_cgminer.rb`). `PoolManager` opens three connections per miner per action (command → `:pools` re-query → `:save`), so the fixture map in `cgminer_fixtures.rb` must include all three response keys. Integration spec `pool_management_spec.rb` exercises this path; the failure mode to watch for is a test hang on a missing fixture key.

### 15.4 CI (GitHub Actions)

Three jobs:

- `lint` — RuboCop on Ruby 3.4.
- `test` — unit + non-FakeCgminer integration specs, matrix `[3.2, 3.3, 3.4, 4.0]` + `head` (allow-fail).
- `integration` — full integration specs (FakeCgminer binds a TCP port), Ruby 3.4 only.

### 15.5 Coverage

- SimpleCov, 90% floor on `lib/`.
- No floor on `views/` or `bin/`.
- No Capybara / browser tests in v1.

## 16. Deployment

- Multi-stage `Dockerfile`, mirroring monitor's.
- `docker-compose.yml` that starts manager + monitor + mongo for local-development parity. Becomes the default "try it locally" story.
- Graceful shutdown: SIGTERM/SIGINT → stop accepting new requests → allow in-flight pool-management commands to finish, 10s cap → force exit if still running. Pattern ported from monitor's `server.rb`.
- Structured JSON logging by default in container; text in dev.
- No systemd unit shipped; documented in README for operators who want one.

## 17. Documentation

- **README.md** rewritten. New install / config / run sections. Rails server + precompile instructions deleted. Docker-first quickstart added.
- **MIGRATION.md** for existing operators:
  - Framework change: Rails → Sinatra.
  - Mongo config removed.
  - `CGMINER_MONITOR_URL` required.
  - `miners.yml` still used; shape unchanged. (Validated against `cgminer_monitor`'s example at repo-init time to avoid drift.)
  - `/api/v1/ping.json` unchanged.
  - Asset pipeline dropped; assets served as plain files.
  - **Miner URLs now use `host:port`.** Old URLs (`/miner/0`) stop working. New URLs are `/miner/10.0.0.5%3A4028` (URL-encoded colon). One-time break for existing bookmarks.
  - **`POST /manager/run` and `POST /miner/:id/run` are removed.** The typed pool-management actions (add/disable/remove/enable/save) remain available via the UI. Operators who relied on arbitrary command execution can use `cgminer_api_client` directly from IRB: `CgminerApiClient::Miner.new('host', port).query(:command)`. Rationale: security blast radius and silent-swallow issues; see § 7.1.
  - **Graph coverage requires a minimum `cgminer_monitor` version.** The dashboard's hardware-error / pool-stale / pool-rejected / device-rejected graphs are backed by `/v2/graph_data/:metric` endpoints that must exist in your deployed monitor. README and CHANGELOG state the minimum monitor release.
  - **Upgrade order.** Monitor (with the new graph endpoints) must be upgraded **before** manager 1.0.0 is deployed. Old (Rails-engine) monitor has no `/v2/*` surface; new manager against old monitor will fail startup. Recommended ritual: (1) upgrade monitor, (2) verify `GET $CGMINER_MONITOR_URL/v2/miners` returns 200, (3) `bin/cgminer_manager doctor` passes, (4) cut over manager. `doctor` (§ 11) asserts monitor responds on `/v2/miners` and fails the check loudly if not — equivalent to refusing to run against a pre-v2 monitor.
  - Rollback: the prior Rails app remains available at the `v0-legacy` tag (§ 18) for at least one release cycle after 1.0.0 ships.
- **CHANGELOG.md** — new, opens with `1.0.0` entry documenting the port.

## 18. Delivery plan

One big-bang port on a feature branch (`modernize/sinatra-port` off `develop`), merged when green. Each phase ends with a passing `rake` / green CI.

- **Phase -1 — `cgminer_monitor` companion PR.** Before manager work starts: extend `cgminer_monitor` with the `/v2/graph_data/:metric` endpoints needed for the diagnostic graphs (hardware error, pool stale/rejected, device rejected, local/miner split) — see § 6.2. Tag a new monitor release; manager 1.0.0 declares it as the minimum required monitor version. Lands independently, no manager coupling.
- **Phase 0 — prep.** `.ruby-version`, `.rubocop.yml`, `.github/workflows/ci.yml`, empty `spec/` with `spec_helper.rb` + SimpleCov. CI runs against empty suite to establish baseline.
- **Phase 1 — skeleton + lib core.** `version`, `errors`, `config`, `logger`. New `Gemfile` and gemspec. Drop Rails, Mongoid, Thin, therubyracer, jquery-rails, sass-rails, Sprockets; add Sinatra, Puma, `http`, RSpec, WebMock, RuboCop. Unit specs for the four core files.
- **Phase 2 — read plane.** `monitor_client.rb` + unit spec. `monitor_stubs.rb` + monitor fixtures.
- **Phase 3 — command plane.** `pool_manager.rb` + unit spec. Port `fake_cgminer.rb` + `cgminer_fixtures.rb` from api_client.
- **Phase 4 — HTTP app + views.** `http_app.rb` wired to `MonitorClient` + `PoolManager`. Port HAML views. Move JS/CSS to `public/`. Integration specs for dashboard, miner page, graph data, ping.
- **Phase 5 — server + CLI.** `server.rb`, `cli.rb`, `bin/cgminer_manager`. `cli_spec`, `full_boot_spec`, `pool_management_spec`.
- **Phase 6 — packaging & docs.** `Dockerfile`, `docker-compose.yml`, README rewrite, `MIGRATION.md`, `CHANGELOG.md`.
- **Phase 7 — unmount Rails, cut 1.0.0.** Delete `config.ru`'s Rails boot (replace with Sinatra's rackup) and remove the Rails `config/environment.rb` load chain, but **leave `app/`, `config/application.rb`, `config/environments/`, `config/routes.rb`, `config/boot.rb`, `lib/tasks/`, and `test/` in place**. Tag the commit just before this phase as `v0-legacy` — that commit is the last one where the old Rails app still boots, and is the documented rollback target. Cut 1.0.0 from the unmount commit.
- **Phase 8 — delete the Rails tree.** After at least one release cycle of 1.0.0 soak (no critical regressions reported), open a separate PR deleting `app/`, `config/application.rb`, `config/environments/`, `config/routes.rb`, `config/boot.rb`, `lib/tasks/`, `test/`, and any Rails-specific initializers. Keep `config/miners.yml.example` and `config/puma.rb`. This ships as 1.1.0 or similar.

**Versioning:** first modernized release is `1.0.0`, declared in a new `cgminer_manager.gemspec` (even though this is an app, not a gem — follows monitor's precedent for `required_ruby_version` gating + metadata). The 1.0 jump signals the Rails-era → Sinatra-era break.

**`Gemfile.lock` is committed** (this is an application, not a library). Matches `cgminer_monitor`'s precedent.

**Branching:** `modernize/sinatra-port` off `develop`. Each phase is one or a small group of commits. Merge to `develop` when all phases are green. Merge `develop` → `master` as the 1.0 release cut. Tag `v0-legacy` on the last-Rails-bootable commit per Phase 7.

## 19. Out of scope

- Re-architecting monitor or api_client. They are upstream dependencies; we consume their current APIs.
- Adding features: auth, multi-user, role-based access, graph customization, alerting beyond the existing audio cue, mobile views.
- Frontend rewrite (Hotwire, React, Vue).
- Replacing Chart.js.
- Persisting anything in manager itself.

## 20. Resolutions

All judgment-call items surfaced during staff review have been resolved and folded into the sections above. Summary for future reference:

| # | Question | Resolution | Section(s) |
|---|----------|------------|------------|
| 1 | Target miner count / fan-out redesign | Accept ~20 miners as the supported scale. No batch-endpoint redesign. Slower render above that is acceptable; if demand appears, remedy is progressive per-tile rendering in a follow-up, not batch API. | § 3, § 6.1 |
| 2 | Missing graph metrics | Preserve all current graphs by adding `/v2/graph_data/:metric` endpoints to `cgminer_monitor` in a companion PR. Manager 1.0.0 declares minimum monitor version. | § 6.2, § 18 Phase -1 |
| 3 | Miner-id scheme | `host:port` end-to-end. URL-encoded. Replaces the fragile integer-array-index scheme. `doctor` validates entries against monitor's list. | § 4.4, § 6.3, § 11, § 17 |
| 4 | Empty-state return shape | Plain hashes (no tri-state type). Views check `response.nil? && error.nil?` for "waiting for first poll." | § 6.1 |
| 5 | Staleness surfacing | Yes. Render "updated Xm ago" warning per tile when `fetched_at` exceeds `STALE_THRESHOLD_SECONDS` (default 300). No per-render `/v2/healthz` call. | § 6.1, § 10 |
| 6 | `addpool` verification + `PoolActionResult` states | Skip verification for `addpool` (trust STATUS=S; ApiError is the failure signal). Keep one-shot bounded re-query for disable/enable/remove. `PoolActionResult` is three-state (`:ok` / `:failed` / `:indeterminate`); `save` is tracked as a separate step. | § 7.3, § 7.4 |
| 7 | `manager#run` / `miner#run` arbitrary-command endpoints | Cut in 1.0.0. Typed `PoolManager` actions cover real use. Operators who need raw access use `cgminer_api_client` from IRB. If post-release demand appears, remedy is a narrow allow-list — not re-opening arbitrary execution. | § 3, § 7.1, § 17 |
| 8 | Observability beyond logs | Per-monitor-call timing log + per-controller-render timing log + `/healthz` thin proxy to `/v2/healthz`. No Prometheus in 1.0.0. | § 3, § 6.5, § 12 |

No open questions remain at spec time.
