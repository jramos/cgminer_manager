# Changelog

## [1.2.0] — 2026-04-17

### Restored (opt-in, hardened)
- **Admin surface on the dashboard + per-miner page**, rolling back the 1.1.0 removal of `POST /manager/run` and `POST /miner/:id/run`. The new surface is:
  - Typed allowlist routes `POST /manager/admin/:command` and `POST /miner/:miner_id/admin/:command` for `version`, `stats`, `devs`, `zero`, `save`, `restart`, `quit`. One click each, typed confirm copy on writes.
  - Raw RPC forms `POST /manager/admin/run` and `POST /miner/:miner_id/admin/run` with `command` + `args` + `scope` params for any cgminer verb not covered by the typed list (device tuning — `pgaset`/`ascset`/`pgarestart`/`ascrestart` — goes through here).
  - Server-side regex constrains `command` to `/\A[a-z][a-z0-9_+]*\z/` (no whitespace, null bytes, or path traversal).
  - Scope-restricted verbs (`pgaset`/`ascset`/`pgarestart`/`ascrestart`/`pga{enable,disable}`/`asc{enable,disable}`) refuse `scope=all` with 422 + `admin.scope_rejected`; UI disables the "all" option when the command matches.
  - Every admin POST emits five structured events (`admin.command`/`admin.raw_command`/`admin.result`/`admin.auth_failed`/`admin.scope_rejected`) threaded by a `request_id` UUID so entry and exit join cleanly.

### Added
- Optional HTTP Basic Auth gate via `CGMINER_MANAGER_ADMIN_USER` + `CGMINER_MANAGER_ADMIN_PASSWORD`. Empty strings treated as unset. When set, admin POSTs require matching Basic Auth credentials; valid creds also bypass CSRF (scripts can curl admin routes).
- `CgminerCommander` service class — thread-cap bounded fan-out for fleet RPC (reads return `FleetQueryResult`, writes return `FleetWriteResult`).
- Optional `label` key on `miners.yml` entries — when present, UI renders the label in place of `host:port` for display. Routing still uses `host:port`.
- Real FakeCgminer fleet in the screenshot harness (`dev/screenshots/fake_cgminer_fleet.rb`) — six TCP listeners on `127.0.0.1:40281-40286` — replaces the previous `CGMINER_MANAGER_FAKE_PING` env hook so admin commands exercise real RPC round-trips end-to-end.
- `public/screenshots/admin.png` — new screenshot showing the Admin tab.

### Changed
- `HttpApp.configured_miners` returns `[host, port, label]` tuples (label defaults to `nil`). Existing `|host, port|` destructuring still works.
- `ViewMiner` gains `.label`, `.host_port`, `.display_label`; `.to_s` returns the label when present.
- Dashboard HAML gains a third tab (Admin, styled danger-red). Miner page HAML gains a fifth tab (Admin).
- `.rubocop.yml`: `Metrics/ClassLength` max raised to 550 to accommodate the admin routes on `HttpApp` without premature extraction.

### Removed
- `CGMINER_MANAGER_FAKE_PING` dev/harness env hook. Real FakeCgminer listeners supersede it.

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
