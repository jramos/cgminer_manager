# Changelog

## [Unreleased]

### Added
- AI-assistant knowledge base under `docs/` (architecture, components,
  interfaces, data models, workflows, dependencies, review notes,
  plus an `index.md` router) and a consolidated `AGENTS.md` at the
  repo root. Not packaged in the gem.
- README subsections for CLI exit codes (0/1/2/64), the gem's error
  taxonomy (`ConfigError`, `MonitorError::{ConnectionError, ApiError}`,
  `PoolManagerError::DidNotConverge`), and a Further Reading list
  linking to CHANGELOG, MIGRATION, AGENTS, docs/, and the two
  sibling repos.

### Fixed
- **Operator-configured `CGMINER_MANAGER_SESSION_SECRET` now actually
  reaches `Rack::Session::Cookie`** (#10). The `use
  Rack::Session::Cookie, secret: ...` middleware wiring previously
  lived in a class-body `configure do … end` block. Sinatra captures
  `use` args at call time — class-body eval — which happens before
  `Server#configure_http_app` populates `settings.session_secret`, so
  every boot silently fell through to `SecureRandom.hex(32)` and
  invalidated all sessions across restarts regardless of env var.
  Moved the middleware stack into a new `HttpApp.install_middleware!`
  class method that Server (and `configure_for_test!`) call after
  settings are populated. Idempotent — re-seeds `@middleware` each
  call so repeated invocations in tests don't stack duplicates.

### Changed
- **`HttpApp` split into routes + HTML/display helpers + three sibling
  pure modules.** View-model construction moved to
  `CgminerManager::ViewModels` (dashboard, per-miner, and miner-pool
  builders, plus the threaded snapshot fan-out — all pure functions
  taking `monitor_client:` / `configured_miners:` /
  `stale_threshold_seconds:` / `pool_thread_cap:` explicitly). Fleet
  adapter factories moved to `CgminerManager::FleetBuilders`
  (`pool_manager_for_all` / `pool_manager_for` / `commander_for_all` /
  `commander_for`). Admin audit-log plumbing moved to
  `CgminerManager::AdminLogging` (`session_id_hash`,
  `command_log_entry`, `result_log_entry`). `HttpApp` keeps one-line
  delegating helpers so Haml templates and route blocks don't change;
  `dispatch_pool_action` and `render_admin_result` stay on `HttpApp`
  because they read Sinatra-scoped state (params for the add-pool
  branch; haml partials). The `Metrics/ClassLength: Max 550` rubocop
  override becomes per-file exclusions on `HttpApp` and `PoolManager`;
  new classes go back to getting the 100-line default.
- **`HttpApp` class-level state moved to Sinatra `settings`.** The
  `class << self` block that held `attr_accessor :monitor_url,
  :miners_file, :stale_threshold_seconds, :pool_thread_cap,
  :monitor_timeout_ms, :session_secret, :production` plus the lazy
  `configured_miners` memo is replaced with eight `set :key, default`
  declarations. `Server#configure_http_app` writes them via
  `HttpApp.set :key, value` (including eagerly parsing miners.yml into
  `settings.configured_miners` via the new
  `HttpApp.parse_miners_file(path)` class method). Routes read via
  `settings.foo`; `configured_miners` has a fail-loud instance helper
  that raises if the setting was never populated. Public
  `HttpApp.configure_for_test!(monitor_url:, miners_file:, ...)`
  preserves its signature so no spec file needed changes.
  Removed: `HttpApp.monitor_url=` / `HttpApp.miners_file=` /
  `HttpApp.stale_threshold_seconds=` / `HttpApp.pool_thread_cap=` /
  `HttpApp.monitor_timeout_ms=` / `HttpApp.session_secret=` /
  `HttpApp.production=` / `HttpApp.reset_configured_miners!`.
- **Frontend purged of jQuery, jQuery UI, and jquery.cookie.** Drops
  ~390 KB (~80 KB gzipped) of vendored JS and the last jQuery-family
  dep surface. Replacements:
  - `public/js/fetch_helpers.js` (new) — `csrfFetch` and `getJSON`
    helpers built on native `fetch`. CSRF token is read once from
    `<meta name="csrf-token">` and injected on non-GET requests.
    Replaces `$.ajaxSetup`, `$.getJSON`, `$.ajax`.
  - `public/js/tabs.js` (new, ~45 LOC) — vanilla replacement for
    jQuery UI's `.tabs()`. Honors `window.location.hash`, fires an
    optional `activate` callback only on user clicks (matching jQuery
    UI's behaviour), and styles the active tab via a `.tab-active`
    class. Dashboard outer tabs wait on `window.__chartsReadyPromise`
    before init so the availability canvas on the Miner Pool panel
    gets laid out at full width before the panel is hidden.
  - `public/js/application.js` — AJAX polling, DOM updates, and the
    `update` CustomEvent bus are all vanilla. `appendWarning` now
    dedupes by id so repeated polls don't stack identical warning
    divs (fixing a latent jQuery-era bug).
  - `public/js/audio.js` — audio-toggle preference persists in
    `localStorage` under `enable-audio` instead of a `$.cookie`.
    Existing cookie-based preferences are not migrated.
  - `public/js/admin.js` — form submission uses `csrfFetch` with
    `URLSearchParams(new FormData(form))`; error body rendering is
    DOM-constructed rather than round-tripped through escaped
    innerHTML.
  - `views/miner/show.haml` update handler replaces jQuery's
    `.load()` with `fetch` + `DOMParser` + script reanimation,
    guarded by an `AbortController` so overlapping `update` ticks
    can't race. `@miner_url` is serialised through `.to_json` to
    block interpolation injection.
- **Chart.js upgraded from 1.0.1-beta.3 (2015) to 4.5.1.** All seven
  graph partials under `views/shared/graphs/` rewrite their configs
  to v4's `new Chart(canvas, { type, data, options })` shape and
  call `Chart.getChart(canvas)?.destroy()` before instantiating so
  the miner-detail `.load()`-equivalent reload path doesn't trip
  v4's "Canvas is already in use" error. `window.__chartsReady`
  and `window.__chartsReadyPromise` are the new vanilla replacements
  for `jQuery.active === 0`; the screenshot harness waits on that
  flag before capturing.
- **Temperature graph renders as three stacked fill bands** (0..Min
  yellow, Min..Avg orange, Avg..Max red) using Chart.js v4's
  relative `fill: '+1'` and `fill: 'origin'` options. Each series
  fills exactly the region between its own line and the next-lower
  series, so the bands are disjoint and all three lines stay
  visible on top.
- **Other graph partials are filled areas** (hashrate, availability,
  hardware_error, device_rejected, pool_rejected, pool_stale) with
  semi-transparent backgrounds, matching the v1 visual with `fillColor`.
- **Dashboard Admin tab buttons are laid out horizontally.** The
  `.admin-button-row` class gets `display: flex` with 8 px gap so
  the Status queries (Version/Stats/Devs) and Fleet operations
  (Zero/Save/Restart/Quit) groups render as one row each instead
  of stacking vertically.
- **Screenshots regenerated.** `public/screenshots/summary.png`,
  `miner-pool.png`, `miner.png`, and `admin.png` all reflect the
  new vanilla tab CSS, Chart.js v4 visuals, the stacked-band
  temperature fill, and the horizontal admin button rows.
- **Session cookie is now `Secure` in production.** `Rack::Session::Cookie`
  gets `secure: true` when `Config#production?`, gated so dev/test on
  `http://127.0.0.1` keeps working. Complements the README's reverse-
  proxy posture.
- **`Config.session_secret` is now the single source of truth** for the
  session cookie secret. Previously `HttpApp`'s `configure` block did
  its own `ENV.fetch('SESSION_SECRET') { SecureRandom.hex(32) }` inline,
  duplicating `Config.resolve_session_secret`'s logic. Now `Server#configure_http_app`
  plumbs `@config.session_secret` into `HttpApp.session_secret` and the
  middleware reads from there.
- **`HttpApp.configured_miners` is force-evaluated at boot.** `Server#configure_http_app`
  now invokes it eagerly, so malformed `miners.yml` surfaces as
  `ConfigError` → CLI exit 2 rather than HTTP 500 on the first request.
- **`MONITOR_TIMEOUT_MS` now takes effect.** `Config#monitor_timeout` flows
  through `HttpApp.monitor_timeout_ms` and into `MonitorClient.new(timeout_ms:)`.
  Previously every monitor call used the client's hardcoded 2-second
  default regardless of env. Same for `bin/cgminer_manager doctor`.

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
