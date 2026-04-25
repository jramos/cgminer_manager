# Changelog

## [Unreleased]

### Changed
- **Resolution source for `cgminer_api_client` switched from git+tag
  override to plain rubygems.** v0.4.0 was published to rubygems
  after `cgminer_manager` v1.6.0 cut, so the temporary `Gemfile`
  override (added in PR #33 to unblock the `on_wire:` kwarg
  requirement) is dropped. Gemspec constraint `~> 0.4` is unchanged;
  downstream consumers now resolve through standard channels. No
  behavior change.

## [1.6.0] — 2026-04-25

### Added
- **Cross-repo trace-id propagation** via the `X-Cgminer-Request-Id`
  HTTP header. New `CgminerManager::RequestId` Rack middleware sits at
  the top of the stack (above `RateLimiter`, `Rack::Session::Cookie`,
  `AdminAuth`, and `ConditionalAuthenticityToken`); generates a UUID v4
  per request or honors an inbound header, stashes the value on
  `env['cgminer_manager.request_id']`, and echoes it in the response.
  `MonitorClient` injects the header on every outbound HTTP call to
  monitor and tags `monitor.call` / `monitor.call.failed` events with
  the same value. `FleetBuilders` builds per-request
  `CgminerApiClient::Miner` instances with an `on_wire:` closure that
  captures the request_id and emits `cgminer.wire` log events tagged
  with it. The `cgminer.wire` event emits at debug level — opt in via
  `LOG_LEVEL=debug` to avoid the ~100-200 events per fan-out at info
  volume. `rate_limit.exceeded`, `admin.auth_failed`,
  `admin.auth_misconfigured` events all gain `request_id`.

- **Audit-retention docs** (`docs/logging.md` "Audit retention" section
  + a brief README pointer). Documents the manager's stdout-only posture
  and how to route + retain audit events via systemd journald, Docker
  logging drivers, or a Vector / Fluent-Bit shipper. The recommended
  audit filter is `event=admin.*` OR `event=rate_limit.exceeded` — the
  latter catches unauthenticated 401-probing because the rate limiter
  sits above the auth gate. No code change; the application has no file
  sink and no runtime dependency on a log backend.
- **Per-miner scheduled-restart window**
  (`lib/cgminer_manager/restart_*.rb`,
  `views/miner/_maintenance.haml`). New "Scheduled Restart" form on every
  miner's Admin tab persists an enable-toggle + UTC time-of-day to a JSON
  store (`data/restart_schedules.json` by default). A `RestartScheduler`
  thread spawned by `Server#run` walks the store every 30 s and fires
  `restart` against any miner whose UTC time-of-day is within ±2 minutes
  of "now" — date-based dedupe (`last_scheduled_date_utc`) ensures each
  schedule fires at most once per UTC calendar day. Two layers of error
  containment: per-tick `rescue StandardError` and a thread-top
  `rescue Exception` (mirrors `Server#start_puma_thread`) so a
  non-StandardError surfaces as `restart.scheduler.crash` rather than
  vanishing the scheduler silently. New routes `GET`/`POST
  /miner/:miner_id/maintenance` (Basic Auth + CSRF + rate limited) and
  the public read endpoint `GET /api/v1/restart_schedules.json` (consumed
  by `cgminer_monitor` to suppress `offline` alerts during a restart
  window). New env vars `CGMINER_MANAGER_RESTART_SCHEDULES_FILE` and
  `CGMINER_MANAGER_RESTART_SCHEDULER` (set to `off` to disable the
  scheduler thread without disabling the routes — useful for multi-host
  deploys where only one node should drive restarts). All three sister
  regexes (`AdminAuth::ADMIN_PATH`, `HttpApp#admin_path?`,
  `RateLimiter::DEFAULT_PATHS`) updated to cover the new path; the
  integration spec asserts 401 without auth and 429 over limit so a
  future regression on any of the three trips a test.
- **Contract test against monitor's OpenAPI spec**
  (`spec/contract/monitor_openapi_contract_spec.rb`). Asserts that
  every envelope key `MonitorClient` + view-models read from
  cgminer_monitor's `/v2/*` responses is declared in the monitor-
  shipped OpenAPI (`lib/cgminer_monitor/openapi.yml`). Catches
  field-rename or envelope-reshape drift at CI time instead of at
  page-load. Scope is envelope-only (`miners`, `host`, `port`,
  `available`, `id`, `ok`, `response`, `error`, `fields`, `data`,
  `status`); cgminer-payload drift stays in api_client territory.
  Monitor is added as a CI-only dev dep in `Gemfile` pinned to
  `tag: 'v1.2.0'` under a `GIT` source — bumping the tag is a
  deliberate reviewable event that surfaces OpenAPI revisions in
  manager's PR history.
- **`docs/logging.md`** — short stub naming the manager-owned log
  event namespaces (`admin.*`, `rate_limit.*`, `monitor.*`, `http.*`),
  the shared namespaces (`server.*`, `reload.*`, `puma.*`), and the
  house conventions. Links to `cgminer_monitor/docs/log_schema.md`
  as the cross-repo source of truth for reserved keys, the full
  event catalog, and evolution rules.

### Changed
- **`request_id` generation moved from admin-only Sinatra `before`-filter
  to the new `RequestId` Rack middleware.** Generation now happens for
  every HTTP request, not just admin paths. Visible consequence:
  `http.request`, `rate_limit.exceeded`, and `admin.auth_failed` events
  now carry `request_id` (previously empty for non-admin requests). No
  API change.
- **Bumped `cgminer_api_client` dependency from `~> 0.3` to `~> 0.4`**
  for the `on_wire:` kwarg on `Miner#initialize` (ships in v0.4.0).
- **Bumped `cgminer_monitor` dev dep pin to `v1.3.1`** (the pin used
  by the `#4.3` OpenAPI contract spec). v1.3.0 + v1.3.1 add the
  monitor side of trace-id propagation; v1.3.1 widens monitor's
  api_client constraint to `>= 0.3, < 0.5` so both can be pinned
  together without a Bundler conflict.
- **Log-key consistency — `duration_ms` everywhere.** The
  `admin.result` and `http.request` log events previously emitted
  their timing under `elapsed_ms` and `render_ms` respectively;
  both now emit `duration_ms` to match `monitor.call` and the
  house-wide standard. No Ruby API change — `AdminLogging.result_log_entry`
  and the `http.request` after-filter still accept the same inputs.
  **Log consumers that keyed off `elapsed_ms` or `render_ms` must
  update their queries to `duration_ms`.** The `cgminer_monitor`
  canonical log-schema doc (`cgminer_monitor/docs/log_schema.md`)
  pins `duration_ms` as the standardized reserved key.
- `docs/interfaces.md`, `docs/workflows.md`, and `docs/architecture.md`
  updated to name `duration_ms` in their event tables and Mermaid
  sequence diagrams.
- Test-support code (FakeCgminer, CgminerFixtures) extracted to the
  shared `cgminer_test_support` gem. `spec/support/monitor_stubs.rb`
  remains manager-specific and unchanged. The
  `dev/screenshots/fake_cgminer_fleet.rb` harness now requires the
  shared gem instead of loading from `spec/support/` via load-path
  manipulation; its bespoke per-scenario response map is unchanged.

## [1.5.0] — 2026-04-22

### Added
- **Rate limiting on admin + write POSTs** (`lib/cgminer_manager/rate_limiter.rb`).
  New Rack middleware throttles POSTs to `/manager/admin/*`,
  `/miner/:id/admin/*`, `/manager/manage_pools`, and
  `/miner/:id/manage_pools` to 60 requests / 60 seconds per client IP
  by default. Over-limit requests receive `429 Too Many Requests`
  with a `Retry-After` header. The limiter sits above
  `Rack::Session::Cookie` + `AdminAuth` so 401-probing attackers are
  throttled before the auth gate ever executes. Fixed-window
  semantics (not sliding); an attacker timing requests at a window
  boundary can push up to 2× the limit in a ~2-second band —
  acceptable for defense-in-depth. In-process state (Hash + Mutex);
  single-Puma-process deployments only. Tune via
  `CGMINER_MANAGER_RATE_LIMIT_REQUESTS` /
  `CGMINER_MANAGER_RATE_LIMIT_WINDOW_SECONDS` or disable with
  `CGMINER_MANAGER_RATE_LIMIT=off`.
- **`CGMINER_MANAGER_TRUSTED_PROXIES` env var** (comma-separated
  CIDRs, default empty). When `REMOTE_ADDR` matches one of the
  configured CIDRs, the rate limiter walks `X-Forwarded-For`
  right-to-left and keys the bucket on the leftmost untrusted hop
  (the real client IP). Without this, the limiter sees every
  request as coming from the reverse proxy's IP and throttles
  globally. Malformed XFF hops fall back to `REMOTE_ADDR` so
  attacker-controlled garbage cannot amplify memory use. README has
  an nginx snippet; `MIGRATION.md` documents the upgrade failure
  mode.
- **`bin/cgminer_manager doctor` reports rate-limit posture.**
  Either `rate-limit: enabled (N req / Ns per IP)` or
  `rate-limit: DISABLED (CGMINER_MANAGER_RATE_LIMIT=off)`, plus
  `trusted-proxies: none (X-Forwarded-For ignored)` or a comma-
  separated CIDR list.
- **`brakeman` in CI** (`.github/workflows/ci.yml`,
  `config/brakeman.yml`). New `brakeman` job runs
  `bundle exec brakeman --force --no-summary --quiet --exit-on-warn`
  on every push and PR, failing CI on any static security warning.
  Brakeman 8.x is Rails-focused; `force_scan: true` in
  `config/brakeman.yml` makes it scan this Sinatra app anyway. The
  Rails-specific checks (Controllers / Models) report zero by design,
  but the ~79 generic-Ruby checks (Execute, Evaluation, Send,
  Deserialize, JSONParsing, TemplateInjection, XSS, etc.) still run
  against `lib/` and the Haml views, covering the admin dashboard
  surface. Also available locally as `bundle exec rake brakeman`.
  First-run result: zero warnings; `config/brakeman.ignore` not
  created.
- **`bundle-audit` in CI** (`.github/workflows/ci.yml`). New `audit`
  job runs `bundle exec bundle-audit check --update` on every push
  and PR, gating merges on known CVEs in `Gemfile.lock`. Also
  available locally as `bundle exec rake audit`.
- **Dependabot config** (`.github/dependabot.yml`). Weekly bump PRs
  for Bundler, GitHub Actions, and Docker `FROM` base images, with
  `open-pull-requests-limit: 3` per ecosystem. `versioning-strategy:
  lockfile-only` on bundler keeps gemspec `~>` bounds stable — the
  lockfile moves forward automatically, but a human widens bounds
  when intent is to adopt a new line. PRs target `develop`.

## [1.4.0] — 2026-04-22

### Added
- **`miners.yml` hot reload via SIGHUP.** Add, remove, or re-label a
  miner without restarting. The Server traps SIGHUP, atomically
  re-parses `settings.miners_file`, and swaps `settings.configured_miners`
  — `PoolManager`, `CgminerCommander`, and the dashboard/per-miner
  routes all read the new list on the next request. Parse or
  validation failures log `event=reload.failed` and keep the previous
  list so a typo can't crash a running server. New CLI verb
  `bin/cgminer_manager reload` reads `CGMINER_MANAGER_PID_FILE`,
  dry-run-parses miners.yml locally (surfacing typos at exit 2 before
  signaling), and sends SIGHUP; `doctor` reports the PID file's
  posture (`not configured` / `OK (pid N)` / `STALE` / `missing`).
  Failure modes `cmd_reload` now surfaces with clean exit 1 instead
  of a stack trace: garbage pid-file contents (`ArgumentError`),
  pid owned by another user (`Errno::EPERM`), stale pid, and
  missing pid file. `puma.crash` logs now include the first 10
  backtrace frames (parity with `cgminer_monitor`).
- **CI publishes multi-arch container images on `v*` tag push.** New
  `.github/workflows/release.yml` builds `linux/amd64` + `linux/arm64`
  images on native GitHub-hosted runners and pushes to
  `ghcr.io/jramos/cgminer_manager` with semver-derived tags
  (`1.2.3` / `1.2` / `1` / `latest`, prerelease-safe) plus SLSA
  provenance and CycloneDX SBOM attestations. A `workflow_dispatch`
  entry point runs ad-hoc builds with a user-supplied tag
  (default `edge`) for smoke tests.

### Changed
- **Thread-cap fan-out extracted to `CgminerManager::ThreadedFanOut.map`.**
  The Queue + fixed-worker + Mutex pattern previously duplicated across
  `CgminerCommander#fan_out`, `PoolManager#run_each`, and
  `ViewModels.fetch_snapshots_for` is now a single pure helper. Callers
  supply a block that returns the per-item result (and handles any
  site-specific error capture); `ThreadedFanOut.map` returns an ordered
  array matching input order. Public API of `CgminerCommander`,
  `PoolManager`, and `ViewModels` is unchanged; the private
  `CgminerCommander#fan_out` and `PoolManager#run_each` helpers (plus
  the `ViewModels` worker helpers `spawn_snapshot_worker` /
  `pop_or_break`) are removed — external monkey-patches of these will
  break.

## [1.3.0] — 2026-04-21

### Changed (BREAKING)
- **Admin Basic Auth is now required by default.** Set
  `CGMINER_MANAGER_ADMIN_USER` and `CGMINER_MANAGER_ADMIN_PASSWORD`
  before boot, or set `CGMINER_MANAGER_ADMIN_AUTH=off` to deliberately
  disable. The server fails to boot with a clear `ConfigError` when
  neither is configured. The opt-in Basic Auth gate added in 1.2.0 is
  now the default-required gate. See `MIGRATION.md`.

### Added
- `CGMINER_MANAGER_ADMIN_AUTH=off` escape hatch for deployments that
  genuinely want anonymous admin (dev loopback, isolated lab).
- `admin.auth_misconfigured` structured log event +
  `503 Service Unavailable` response on admin paths when boot-time
  validation is bypassed at runtime (env tampering post-boot).
- `bin/cgminer_manager doctor` reports the active admin-auth posture
  (`required (credentials configured)`,
  `DISABLED (CGMINER_MANAGER_ADMIN_AUTH=off)`, or
  `misconfigured` as a failure).
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
