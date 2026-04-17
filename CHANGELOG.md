# Changelog

## [1.1.0] — 2026-04-17

### Added
- Rich dashboard UI restored: per-miner hashrate + devices tables, 6 summary graphs (hashrate, temperature, hardware_error, device_rejected, pool_rejected, pool_stale).
- Rich per-miner page restored: 4-tab layout (Miner / Devs / Pools / Stats), prev/next navigation, per-miner graph canvases.
- `SnapshotAdapter` — converts monitor's `/v2/miners/:id/:type` envelope to the nested shape legacy HAML partials read, with cgminer_api_client-compatible key sanitization (`"Device Hardware%"` → `:'device_hardware%'`, `"MHS 5s"` → `:mhs_5s`).
- `ViewMiner` / `ViewMinerPool` `Data.define` structs for view compatibility (`.host`, `.port`, `.available?`, value equality for `.uniq!`).
- New Sinatra URL patterns: `GET /graph_data/:metric` (dashboard aggregate) and `GET /miner/:miner_id/graph_data/:metric` (per-miner) — both return JSON arrays the Chart.js JS consumes.
- Rails-era helper shims: `format_hashrate`, `number_with_delimiter`, `time_ago_in_words`, `get_stats_for`, `to_ferinheight`.
- `spec/integration/dashboard_rich_spec.rb`, `spec/integration/miner_page_rich_spec.rb`, `spec/integration/miner_page_outage_spec.rb` — cover 6-graph rendering, 4-tab anchors, graceful degradation when per-tile monitor calls 5xx.

### Changed
- `/v2/graph_data/hashrate` proxy now emits all 7 monitor columns (`[ts, ghs_5s, ghs_av, device_hardware_pct, device_rejected_pct, pool_rejected_pct, pool_stale_pct]`) so the 4 error-rate graph partials can index `response[3]` through `response[6]` — matches legacy JS.
- `MonitorClient#graph_data(miner_id: nil)` — nil miner omits the `miner=` query param, supporting monitor's aggregate mode.
- Dashboard route populates `@miner_pool`, `@miner_data`, `@bad_chain_elements` so legacy partials render unchanged.
- Per-miner route: `@miner_id` is now an Integer index into `configured_miners` (was the `host:port` string); the routing string moved to `@miner_host_port`. Unlocks legacy `@miner_id - 1` / `@miner_id + 1` arithmetic while keeping Sinatra routing correct.
- `_availability.haml` per-miner JS fixed (was producing NaN because monitor returns only 2 columns in per-miner mode, not 3).

### Removed
- Entire legacy Rails tree: `app/`, `config/application.rb`, `config/boot.rb`, `config/environment.rb`, `config/routes.rb`, `config/environments/`, `config/initializers/`, `config/locales/`, `config/secrets.yml`, `lib/tasks/`, `test/`, and Rails binstubs (`bin/bundle`, `bin/rails`, `bin/rake`, `bin/spring`). Kept `bin/cgminer_manager`, `config/miners.yml.example`, `config/puma.rb`, `config.ru`.
- `v0-legacy` git tag remains as the rollback reference point (last commit where `rails server` still booted).

## [1.0.0] — 2026-04-17

### Added
- Sinatra + Puma service replaces the previous Rails 4.2 app.
- `bin/cgminer_manager` CLI with `run`, `doctor`, `version` verbs.
- `CgminerMonitorClient` — HTTP client for `cgminer_monitor`'s `/v2/*` API.
- `PoolManager` service object with three-state `PoolActionResult` (`:ok` / `:failed` / `:indeterminate`). `save` is tracked per miner as a separate step.
- `/healthz` endpoint (thin proxy to monitor's `/v2/healthz` + local miners.yml parse).
- Stale-data warning badge on each dashboard tile when `fetched_at` exceeds `STALE_THRESHOLD_SECONDS`.
- "Waiting for first poll" placeholder when monitor has a miner but no samples yet.
- Structured JSON/text logger; per-monitor-call and per-request timing logs.
- Rack-protection CSRF with `X-CSRF-Token` header for XHR flows.
- Multi-stage Dockerfile; `docker-compose.yml` bundling manager + monitor + mongo.
- RSpec + WebMock test suite with FakeCgminer integration; GitHub Actions CI (Ruby 3.2 / 3.3 / 3.4 + optional 4.0 / head nightly).

### Changed
- Ruby floor: **3.2** (gemspec), pinned to **4.0.2** in `.ruby-version`.
- Miner URL scheme: `host:port` (URL-encoded) replaces the array-index scheme. Bookmarks from 0.x break one-time.
- Graph endpoints now reshape monitor's `{fields, data}` envelope to the `[[ts, v1, v2, ...]]` shape `graph.js` expects.

### Removed
- Rails 4.2, Mongoid 4, Thin, therubyracer, Sprockets, jquery-rails, sass-rails, coffee-rails.
- `config/mongoid.yml` (manager no longer connects to MongoDB).
- Arbitrary-command endpoints `POST /manager/run` and `POST /miner/:id/run`.
