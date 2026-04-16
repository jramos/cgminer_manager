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
- Adding features beyond what exists today.

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
                      ├─ MonitorClient#summary(miner_id) etc.  ──HTTP──▶ monitor /v2/miners/:id/summary
                      └─ HAML rendering with plain hashes
```

- Controller action builds a view model (list of miners, each with latest summary/devs/pools/stats) and passes it to HAML.
- `MonitorClient` issues `/v2/miners/:id/*` calls in parallel across miners via a bounded thread pool (cap ~8). Per-call timeout 2s. Page-total budget ~5s.
- On monitor unavailable: `MonitorError` raised by client, caught in controller, dashboard shell renders with a "data source unavailable" banner and whatever partial data came back. No 500.
- Rationale: splitting manager from monitor's data plane is pointless if a monitor outage takes the command plane down too.

### 6.2 Graph data path (per-miner graphs)

```
Browser JS ──GET /miner/:id/graph_data/hashrate?since=…──▶ Sinatra
                                                              │
                                                              └─ MonitorClient#graph_data ──▶ monitor /v2/graph_data/hashrate?miner=:id&since=…
                                                                                           ◀── JSON passes through
```

Manager's `/miner/:id/graph_data/*` is a thin pass-through. Shape is reshaped only if needed for the existing Chart.js contract; default is literal pass-through. Preserves the browser-side `graph.js` behavior.

### 6.3 Command path (pool management)

```
Browser ──POST /manager/manage_pools──▶ Sinatra
                                          │
                                          └─ PoolManager#disable_pool(miner_ids, url)
                                                │
                                                ├─ miners loaded from miners.yml
                                                ├─ for each miner in bounded thread pool:
                                                │     CgminerApiClient::Miner#disablepool / removepool / addpool
                                                │     bounded verification: one re-query of :pools (~2s socket timeout)
                                                │     CgminerApiClient::Miner#query(:save)
                                                └─ returns PoolActionResult (per-miner status + reason)
                                          │
                                          └─ render response with per-miner outcome
```

- No unbounded `while` loop; no unconditional `sleep(5)`. One verification query with a socket-level timeout; if state has not converged, we render "command sent, state did not converge in 2s" — we never hang.
- Rescues narrowed to `CgminerApiClient::ConnectionError` / `TimeoutError` / `ApiError`. `StandardError` is not caught.
- Partial success (e.g., 3 of 5 miners accepted the command) is a first-class render state.

### 6.4 Compatibility endpoint

```
Probe ──GET /api/v1/ping.json──▶ Sinatra
                                   │
                                   └─ MonitorClient#miners → count where availability ok → { ok: N }
```

Preserves the existing JSON shape for any external probe already hitting this path.

## 7. Pool-management rewrite (PoolManager)

The current `app/helpers/miner_helper.rb` is the single worst piece of code in the app. For each pool-management action it:

1. `Thread.new` per miner.
2. `sleep(5)` unconditionally.
3. Polls `@miner.query(:pools)` in an unbounded loop waiting for state convergence.
4. Rescues bare `Exception` and silently logs.
5. Calls `@miner.query(:save)`.

The rewrite in `lib/cgminer_manager/pool_manager.rb`:

- Public API is one method per action: `add_pool`, `disable_pool`, `remove_pool`, `enable_pool`, returning a `PoolActionResult`.
- `PoolActionResult` holds per-miner `{ miner:, status: :ok | :failed, reason: Exception | nil }` entries. Exceptions are retained on the result, not swallowed.
- Execution uses a bounded thread pool (size matches miner count up to a small cap, e.g., 8).
- Bounded verification: one `:pools` re-query after the command, with the socket-level timeout from `cgminer_api_client`. If the expected state is not observed, that miner's entry becomes `{ status: :failed, reason: PoolManager::DidNotConverge }`. We do not loop.
- Rescues: only `CgminerApiClient::ConnectionError`, `CgminerApiClient::TimeoutError`, `CgminerApiClient::ApiError`. Other exceptions propagate.
- Controller renders the `PoolActionResult` — the user sees exactly which miners succeeded and which did not, and why.

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
  - `#miners` → array of miner descriptors.
  - `#summary(miner_id)`, `#devs(miner_id)`, `#pools(miner_id)`, `#stats(miner_id)` → latest per-miner document.
  - `#graph_data(metric:, miner_id:, since:)` → time-series array.
- **Config:** `CGMINER_MONITOR_URL` env var pointing at a running monitor (default host/port per monitor's README).
- **Miners list:** `config/miners.yml` stays. It is the command-plane whitelist — the set of hosts this service is allowed to send cgminer commands to — and is independent of whatever monitor knows.
- **No `mongoid.yml`.** Removed from the repo.
- **Timeouts:** 2s per call. No retry.
- **Typed value objects over the wire:** not for v1. Plain hashes. Add wrappers later if any call site gets messy.

## 10. Configuration

- `CGMINER_MONITOR_URL` — required. Base URL for monitor.
- `MINERS_FILE` — default `config/miners.yml`.
- `PORT` — default `3000` (preserves current behavior).
- `BIND` — default `127.0.0.1` (preserves "local network only" posture).
- `LOG_FORMAT` — `json` or `text`, default `text` in dev, `json` in prod.
- `LOG_LEVEL` — default `info`.

Loaded into a `Config` value object via `Data.define`, mirroring `cgminer_monitor/lib/cgminer_monitor/config.rb`.

## 11. CLI

`bin/cgminer_manager` dispatches:

- `run` — start Puma + Sinatra. Install SIGTERM/SIGINT handlers. Graceful shutdown.
- `doctor` — parse `miners.yml`; for each miner, `CgminerApiClient::Miner#available?`; attempt `GET CGMINER_MONITOR_URL/v2/miners`. Print pass/fail per check. Exit 0 if all pass, non-zero otherwise.
- `version` — print `CgminerManager::VERSION`.

No `migrate` verb (no schema).

## 12. Logging

- Module-level (`CgminerManager::Logger`) with class methods `info`, `warn`, `error`, `debug`.
- Dual format: JSON (default in prod) and human-readable text (default in dev).
- Level filtering via `LOG_LEVEL`.
- Thread-safe. Direct port of monitor's logger.

## 13. Authentication and security posture

- No auth added. Default bind stays at `127.0.0.1`. Operators who expose the service on a network do so via a reverse proxy they control.
- CSRF: pool-management POST endpoints include a CSRF token on form render, verified on submit. Tokens are carried in Sinatra's cookie-based sessions (signed, client-side — no server-side state, consistent with § 4 "manager owns no state"). Rack-protection provides the enforcement middleware.

## 14. UI preservation

- HAML templates from `app/views/**/*.haml` port to `views/**/*.haml` with Rails helper calls swapped for Sinatra equivalents (`link_to` becomes either Sinatra `url` helper or a small local helper; `form_for` becomes an explicit `<form>` tag with the CSRF token inlined).
- `app/assets/javascripts/{chart.min.js, manager.js, miner.js, audio.js, graph.js, config.js, jquery.min.js}` move to `public/js/` verbatim.
- `app/assets/stylesheets/*.css` move to `public/css/`.
- Sprockets, therubyracer, jquery-rails, sass-rails, coffee-rails — all removed.
- Layout references assets by explicit `<script src="/js/…">` / `<link href="/css/…">` tags.
- No bundler, no transpile step.

## 15. Testing strategy

Three layers.

### 15.1 Unit (`spec/cgminer_manager/`) — one file per `lib/` file

- `config_spec.rb` — env parsing, miners.yml loading, validation errors.
- `logger_spec.rb` — JSON vs text format, level filtering, thread-safety smoke.
- `errors_spec.rb` — hierarchy shape.
- `monitor_client_spec.rb` — WebMock-stubbed responses; one test per endpoint for happy path, one for 5xx → `MonitorError::ApiError`, one for connection refused → `MonitorError::ConnectionError`, one for timeout.
- `pool_manager_spec.rb` — `CgminerApiClient::Miner` stubbed via `instance_double`; covers add/disable/remove/save, per-miner partial success, bounded verification timeout, error passthrough.
- `cli_spec.rb` — `Open3`-driven end-to-end for `run` (boot + graceful shutdown), `doctor`, `version`, unknown verb.

### 15.2 Integration (`spec/integration/`) — real Sinatra app, real `cgminer_api_client`, stubbed externals

- `dashboard_spec.rb` — `Rack::Test` drives `GET /`. Monitor stubbed via WebMock. Two variants: all monitor calls succeed; all monitor calls fail (banner appears, no 500).
- `miner_page_spec.rb` — `Rack::Test` drives `GET /miner/:id`. Same pattern.
- `graph_data_spec.rb` — verifies pass-through shape matches what `graph.js` expects.
- `pool_management_spec.rb` — `Rack::Test` drives `POST /manager/manage_pools` and `POST /miner/:id/manage_pools`. Command plane uses **real** `cgminer_api_client` against `FakeCgminer` (ported from api_client's `spec/support/fake_cgminer.rb`) to exercise the real socket and PoolResult unwrap. Covers: all-ok, one-miner-down (ConnectionError), ApiError from cgminer, verification-did-not-converge.
- `ping_spec.rb` — `/api/v1/ping.json` shape preservation.
- `full_boot_spec.rb` — boot real `Server` against FakeCgminer + WebMock-stubbed monitor, issue one HTTP request via `Rack::Test`, stop gracefully. Mirrors monitor's `full_pipeline_spec.rb`. Catches "I broke the wiring."

### 15.3 Fixtures

- Port `FakeCgminer` and `cgminer_fixtures.rb` from `cgminer_api_client/spec/support/`.
- Add `monitor_stubs.rb` with helpers (`stub_monitor_miners`, `stub_monitor_summary`, etc.) wrapping WebMock.
- Monitor response fixture JSON under `spec/fixtures/monitor/`.

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
  - `miners.yml` still used; shape unchanged.
  - `/api/v1/ping.json` unchanged.
  - Asset pipeline dropped; assets served as plain files.
- **CHANGELOG.md** — new, opens with `1.0.0` entry documenting the port.

## 18. Delivery plan

One big-bang port on a feature branch (`modernize/sinatra-port` off `develop`), merged when green. Each phase ends with a passing `rake` / green CI.

- **Phase 0 — prep.** `.ruby-version`, `.rubocop.yml`, `.github/workflows/ci.yml`, empty `spec/` with `spec_helper.rb` + SimpleCov. CI runs against empty suite to establish baseline.
- **Phase 1 — skeleton + lib core.** `version`, `errors`, `config`, `logger`. New `Gemfile` and gemspec. Drop Rails, Mongoid, Thin, therubyracer, jquery-rails, sass-rails, Sprockets; add Sinatra, Puma, `http`, RSpec, WebMock, RuboCop. Unit specs for the four core files.
- **Phase 2 — read plane.** `monitor_client.rb` + unit spec. `monitor_stubs.rb` + monitor fixtures.
- **Phase 3 — command plane.** `pool_manager.rb` + unit spec. Port `fake_cgminer.rb` + `cgminer_fixtures.rb` from api_client.
- **Phase 4 — HTTP app + views.** `http_app.rb` wired to `MonitorClient` + `PoolManager`. Port HAML views. Move JS/CSS to `public/`. Integration specs for dashboard, miner page, graph data, ping.
- **Phase 5 — server + CLI.** `server.rb`, `cli.rb`, `bin/cgminer_manager`. `cli_spec`, `full_boot_spec`, `pool_management_spec`.
- **Phase 6 — packaging & docs.** `Dockerfile`, `docker-compose.yml`, README rewrite, `MIGRATION.md`, `CHANGELOG.md`.
- **Phase 7 — delete the old app.** Remove `app/`, Rails config (`config/application.rb`, `environments/`, `routes.rb`, `boot.rb`, `environment.rb`), `config.ru`, `lib/tasks/`, `test/`, Rails-specific initializers. Keep `config/miners.yml.example` and `config/puma.rb`.

**Versioning:** first modernized release is `1.0.0`, declared in a new `cgminer_manager.gemspec` (even though this is an app, not a gem — follows monitor's precedent for `required_ruby_version` gating + metadata). The 1.0 jump signals the Rails-era → Sinatra-era break.

**Branching:** `modernize/sinatra-port` off `develop`. Each phase is one or a small group of commits. Merge to `develop` when all phases are green. Merge `develop` → `master` as the 1.0 release cut.

## 19. Out of scope

- Re-architecting monitor or api_client. They are upstream dependencies; we consume their current APIs.
- Adding features: auth, multi-user, role-based access, graph customization, alerting beyond the existing audio cue, mobile views.
- Frontend rewrite (Hotwire, React, Vue).
- Replacing Chart.js.
- Persisting anything in manager itself.

## 20. Open questions

None at spec time. All architectural decisions resolved with the user during brainstorming.
