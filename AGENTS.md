# AGENTS.md — `cgminer_manager`

Consolidated context for AI coding assistants. For end-user docs, see [`README.md`](README.md). For release history and the 0.x Rails → 1.0 Sinatra migration, see [`CHANGELOG.md`](CHANGELOG.md) and [`MIGRATION.md`](MIGRATION.md). For deep dives on any topic below, see [`docs/`](docs/) (start with [`docs/index.md`](docs/index.md)).

## Table of contents

- [What this is](#what-this-is)
- [Repo layout](#repo-layout)
- [How the pieces fit together](#how-the-pieces-fit-together)
- [Conventions that matter when editing code](#conventions-that-matter-when-editing-code)
- [Running tests and lint](#running-tests-and-lint)
- [Adding a new HTTP route](#adding-a-new-http-route)
- [Adding a new graph metric](#adding-a-new-graph-metric)
- [Adding a new admin command](#adding-a-new-admin-command)
- [Ruby version support](#ruby-version-support)
- [Gotchas worth knowing up front](#gotchas-worth-knowing-up-front)
- [Release process](#release-process)
- [Where to look for deeper context](#where-to-look-for-deeper-context)

---

## What this is

<!-- metadata: overview, stack, purpose -->

A **Sinatra + Puma web UI** for operating cgminer mining rigs. Sits at the top of a three-gem chain:

- `cgminer_api_client` (TCP client for cgminer's JSON API) — used for write-path ops (pool management, admin RPC).
- `cgminer_monitor` (daemon + MongoDB-backed HTTP API) — used for read-path data (dashboard, graphs, per-miner snapshots).
- `cgminer_manager` (this repo) — orchestrates the UI on top of both.

**Stack:** Ruby 3.2+, Sinatra 4.0, sinatra-contrib, Puma 6.4, HAML 6, `http` gem 5.2, `rack-protection` 4.0. No MongoDB, no Rails, no asset pipeline. ~1.5K SLOC in `lib/`, ~2.2K in `spec/`.

**Execution model:** `cgminer_manager run` starts a single foreground process with Puma embedded. SIGTERM/SIGINT → graceful shutdown, exit 0. Config errors → exit 2. Unknown CLI verb → exit 64. No background workers, no daemonize, no PID file.

## Repo layout

<!-- metadata: directory-structure, file-organization -->

```
├── bin/cgminer_manager             # CLI: run / doctor / version (packaged)
├── lib/cgminer_manager.rb          # require graph only
├── lib/cgminer_manager/
│   ├── admin_auth.rb               # AdminAuth middleware + ConditionalAuthenticityToken
│   ├── cgminer_commander.rb        # Thread-cap fan-out for fleet admin RPC
│   ├── cli.rb                      # Verb dispatch + exit codes
│   ├── config.rb                   # Data.define Config from env + validation
│   ├── errors.rb                   # Error, ConfigError, MonitorError { Connection, Api }, PoolManagerError::DidNotConverge
│   ├── fleet_query_result.rb       # FleetQueryEntry + FleetQueryResult (Data.define)
│   ├── fleet_write_result.rb       # FleetWriteEntry + FleetWriteResult (Data.define)
│   ├── http_app.rb                 # Sinatra app: 14 routes + HTML/display helpers + middleware (~650 LOC)
│   ├── view_models.rb              # Pure view-model builders — no Sinatra, no Rack::Test needed
│   ├── fleet_builders.rb           # Pure PoolManager / CgminerCommander factories
│   ├── admin_logging.rb            # Pure session-id hashing + admin log-entry construction
│   ├── logger.rb                   # Structured JSON/text logger (module singleton, thread-safe)
│   ├── monitor_client.rb           # HTTP client for cgminer_monitor /v2/*
│   ├── pool_manager.rb             # PoolManager + MinerEntry + PoolActionResult (Data.define)
│   ├── server.rb                   # Orchestrator: signals, Puma launcher, shutdown
│   ├── snapshot_adapter.rb         # Monitor envelope → legacy HAML shape translation
│   ├── version.rb                  # VERSION = "1.2.0"
│   └── view_miner.rb               # ViewMiner + ViewMinerPool (Data.define value types)
├── views/                          # HAML templates (packaged)
│   ├── layout.haml, _header.haml, _footer.haml
│   ├── manager/ (_summary, _miner_pool, _admin, index)
│   ├── miner/ (_summary, _devices, _pools, _stats, _admin, show)
│   ├── shared/ (_fleet_query, _fleet_write, _manage_pools, _miner_*, _warnings, graphs/*)
│   └── errors/ (404, 500)
├── public/                         # Static assets served by Puma (packaged): css, js, audio, screenshots, fonts
├── config/
│   ├── miners.yml.example          # [{ host, port, [label] }]
│   └── puma.rb                     # For direct `puma`/`rackup`; NOT used by `run` (Server builds its own launcher)
├── config.ru                       # Rack entrypoint — matches build_puma_launcher without signals/shutdown
├── spec/                           # RSpec unit + integration (NOT packaged)
│   ├── cgminer_manager/            # Unit, one per lib/ file
│   ├── integration/                # HTTP-level tagged :integration
│   ├── fixtures/monitor/*.json     # Canned monitor /v2/* responses
│   └── support/ (cgminer_fixtures, fake_cgminer, monitor_stubs)
├── dev/screenshots/                # Scripted Playwright harness; launches 6 real TCP listeners + fake monitor
├── docs/                           # AI-assistant knowledge base (you're reading from here)
├── .github/workflows/
│   ├── ci.yml                      # lint + test matrix (3.2/3.3/3.4) + integration jobs
│   └── nightly.yml                 # Ruby 4.0 / head experimental
├── .rubocop.yml                    # TargetRubyVersion 3.2; Metrics/ClassLength excluded for HttpApp + PoolManager
├── .rspec, .ruby-version
├── Rakefile                        # default: [rubocop, spec]
├── Dockerfile                      # multi-stage, ruby:3.4-slim
├── docker-compose.yml              # manager + monitor + mongo
├── Gemfile
├── cgminer_manager.gemspec
├── CHANGELOG.md                    # Keep-a-Changelog; 1.2.0 → 1.0.0
├── MIGRATION.md                    # 0.x Rails → 1.0 Sinatra upgrade
├── README.md
└── LICENSE.txt                     # MIT
```

**Packaged in the gem** (gemspec `spec.files`): `lib/**/*`, `views/**/*`, `public/**/*`, `bin/*`, `config/*.example`, `config/puma.rb`, `config.ru`, README, MIGRATION, CHANGELOG, LICENSE. **Not packaged:** `spec/`, `dev/`, `.github/`, `Dockerfile`, `docker-compose.yml`, `docs/`.

## How the pieces fit together

<!-- metadata: architecture, dataflow -->

```
bin/cgminer_manager run
      │
      ▼
   CLI → Server → Puma → HttpApp (Sinatra)
                            │
                            ├── Rack::Session::Cookie ─┐
                            ├── AdminAuth              │ middleware
                            └── ConditionalAuthenticityToken ┘
                            │
                            ├── read path: MonitorClient ── HTTP ──> cgminer_monitor ── Mongo (not ours)
                            │                                    └── /v2/miners, /v2/miners/:id/:type, /v2/graph_data/:metric
                            │
                            └── write path: CgminerCommander ── TCP (via cgminer_api_client) ──> cgminer
                                            PoolManager      ── TCP (via cgminer_api_client) ──> cgminer
```

**Key structural facts:**

1. **Two upstreams with different transports.** HTTP to `cgminer_monitor` for reads, TCP direct to cgminer for writes. The manager never reads cgminer directly for dashboard tiles (that's monitor's job) and never writes to Mongo.
2. **Single-process, foreground, no background workers.** Supervisor-driven.
3. **`HttpApp` state lives in Sinatra settings** set by `Server#configure_http_app` at boot: `settings.monitor_url`, `settings.miners_file`, `settings.stale_threshold_seconds`, `settings.pool_thread_cap`, `settings.monitor_timeout_ms`, `settings.session_secret`, `settings.production`, and `settings.configured_miners` (eagerly parsed at boot via `HttpApp.parse_miners_file`). Tests populate them in one call via `HttpApp.configure_for_test!(...)`.
4. **`Config` is immutable** (`Data.define`). Validated at boot. **Exception:** `AdminAuth` reads `CGMINER_MANAGER_ADMIN_USER`/`_PASSWORD` per-request — deliberate, so dev harnesses can toggle auth without restart.
5. **`CgminerApiClient::Miner.to_s` is monkey-patched** at the top of `http_app.rb` to return `"host:port"`. Upstream doesn't define it; `respond_to_missing?` excludes `to_*`, so it's a safe host-side addition. Makes `FleetWriteEntry.miner` and `MinerEntry.miner` display stable identifiers.
6. **Admin surface has 4 defensive layers.** In order: (a) CSRF via `ConditionalAuthenticityToken`, (b) optional Basic Auth via `AdminAuth` — valid Basic Auth bypasses CSRF, (c) scope restrictions on hardware-tuning verbs (refuse `scope=all`), (d) per-request audit logging threaded by `request_id`. The typed-allowlist on `/manager/admin/:command` is **ergonomic** (UI buttons), not defensive — anyone who can reach `/admin/run` can run any cgminer verb.
7. **Thread-cap fan-out pattern** appears three times: `ViewModels.fetch_snapshots_for`, `CgminerCommander#fan_out`, `PoolManager#run_each`. All three use `Queue` + fixed worker count + `Mutex`-protected results. Default cap is 8 via `POOL_THREAD_CAP`.
8. **No OpenAPI spec** (unlike `cgminer_monitor`). If you add one, also add a CI parity check.

## Conventions that matter when editing code

<!-- metadata: coding-style, conventions, best-practices -->

### Ruby style

- **Every file starts with `# frozen_string_literal: true`.** Enforced by RuboCop. New files too.
- **`Data.define` for immutable value objects**, not `Struct` or custom classes. See `Config`, `ViewMiner`, `FleetQueryResult`/`Entry`, `FleetWriteResult`/`Entry`, `PoolManager::MinerEntry`, `PoolActionResult`.
- **Endless method definitions** are the preferred shape for one-liners (`def method = ...`). Used extensively in `MonitorClient`, `Logger`, `ViewMiner`, the Data.define helpers, `HttpApp` URL builders.
- **Explicit `StandardError` in bare rescues.** The one `rescue Exception` in the codebase is in `Server#start_puma_thread` and carries a RuboCop disable comment — it's intentional there so Puma crashes reliably push to `@stop`.
- **Structured logging everywhere.** `Logger.info(event: 'foo.bar', ...)` with keyword args. Every event has an `event:` key for grep-ability. No `warn`/`puts`/`$stderr` in `lib/`. The only direct `warn` is in `bin/cgminer_manager`'s unknown-verb branch, `Config.resolve_session_secret`'s ephemeral-secret fallback, and `CLI#run`'s `rescue ConfigError`.
- **`YAML.safe_load_file`**, not `YAML.load_file`.
- **Don't mutate `Config` at runtime.**

### RuboCop

- `.rubocop.yml` disables `Style/Documentation` and tunes `Metrics/*`: `MethodLength` max 25, `ClassLength` max 550 (for `HttpApp`), `AbcSize` max 25.
- `Metrics/BlockLength` excludes `spec/**/*` and `lib/cgminer_manager/http_app.rb` (Sinatra route blocks).
- Correctness cops stay on.
- `Naming/MethodParameterName` allowed names: `ok`, `ts`, `v` (Mongo-idiom; inherited from the sibling repos, not used much here).

### Commit style

- **One commit per logical step.** Multi-step changes should land with one commit per step, and `bundle exec rake` should pass before each commit.
- Imperative mood ("Add X", "Fix Y"). Look at recent `git log` for the project's voice — conventional-commits-ish (`feat(...)`, `fix(...)`) when describing releases, free-form otherwise.

### Error handling

- New errors should subclass `CgminerManager::Error` or one of its existing children (`ConfigError`, `MonitorError`, `MonitorError::ConnectionError`, `MonitorError::ApiError`).
- **Rescue narrowly.** `MonitorClient#get` catches three specific transport exceptions; `PoolManager#safe_call` catches three cgminer_api_client error classes. Don't add broad `rescue StandardError` without a specific reason.
- **Don't silently swallow.** `HttpApp#safe_fetch` returns `{error: msg}` on `MonitorError` rescue, which the partial then renders as a "data source unavailable" placeholder. That's *structural* handling, not a swallow. Follow that pattern.

### Testing

- **Unit specs live at `spec/cgminer_manager/**`**, one file per `lib/` file (roughly).
- **Integration specs at `spec/integration/`**, tagged `:integration`. They use `Rack::Test::Methods` against `HttpApp` — no Puma spin-up.
- **Monitor calls are stubbed with WebMock**. See `spec/support/monitor_stubs.rb` for helpers that stub `/v2/*` with fixture JSON.
- **cgminer calls use `FakeCgminer`** (the shared in-process TCP server from `spec/support/fake_cgminer.rb`).
- **Specs that render routes call `HttpApp.configure_for_test!(monitor_url:, miners_file:, ...)`** in a `before` block. It populates every Sinatra setting (including eagerly parsing `miners_file` into `settings.configured_miners`) so the suite is order-independent without a separate reset step.
- **Warnings are deliberately on** in `.rspec`. Keep the suite warning-clean.
- `config.order = :random` — specs must be order-independent.
- `mocks.verify_partial_doubles = true` — doubles must match real signatures.

## Running tests and lint

<!-- metadata: testing, local-dev, commands -->

```sh
bundle install
bundle exec rake                                     # rubocop + rspec (full suite)
bundle exec rspec --tag ~integration                 # unit only (what the CI test matrix runs)
bundle exec rspec --tag integration                  # integration only
bundle exec rspec path/to/spec.rb:123                # single example
bundle exec rubocop                                  # lint only
bundle exec rubocop -A                               # lint + auto-correct
```

Coverage is always on (SimpleCov, enforced at the default rake task via `ENFORCE_COVERAGE=1`). Reports in `coverage/` — `.gitignore`d.

**No external services required for `bundle exec rake`.** No MongoDB, no live monitor, no cgminer. Everything is WebMock + FakeCgminer in-process.

**Regenerating screenshots:**

```sh
cd dev/screenshots
./boot.sh    # launches 6 fake cgminers + fake monitor + manager
# Playwright drives the UI via scenario.rb
./teardown.sh
```

**Refreshing monitor fixtures:**

```sh
CGMINER_MONITOR_URL=http://monitor.local:9292 bundle exec rake spec:refresh_monitor_fixtures
```

## Adding a new HTTP route

<!-- metadata: extending, how-to -->

1. **Add the Sinatra route** in `lib/cgminer_manager/http_app.rb`. Match the existing section ordering (Health → Prometheus-ish → Miners → Miner detail → Graph data → Admin → OpenAPI/Docs → Errors).
2. **Decide on CSRF and Basic Auth shape.** Non-admin POSTs need CSRF. Admin POSTs match the `%r{\A/(manager|miner/[^/]+)/admin(/|\z)}` path regex and get both CSRF and Basic Auth gating automatically.
3. **Write an integration spec** in `spec/integration/` using `Rack::Test::Methods`. Tag `:integration`. Cover happy path, error cases, auth/CSRF cases if it's an admin POST.
4. **Update `interfaces.md`** in `docs/` with the new route entry — same column shape as the existing table.
5. **No OpenAPI update needed** (we don't have one). If we add one later, this step becomes required.

## Adding a new graph metric

<!-- metadata: extending, how-to -->

1. **Add the column projection** to `GRAPH_METRIC_PROJECTIONS` in `lib/cgminer_manager/http_app.rb`: metric name → ordered list of column names (the first should be `ts`).
2. **Make sure monitor exposes the columns.** The projection reads from monitor's `/v2/graph_data/:metric` response `fields`/`data`. If monitor doesn't return a column you're projecting, the projection fills `nil` for that slot.
3. **Add a HAML partial** under `views/shared/graphs/_<metric>.haml` if the metric needs a distinct Chart.js canvas. Follow the existing 6-graph pattern (`_hashrate.haml`, `_temperature.haml`, etc.).
4. **Wire the partial into `views/manager/_summary.haml`** (dashboard) and/or per-miner views.
5. **Test via `spec/integration/graph_data_spec.rb`** or add a new spec.

## Adding a new admin command

<!-- metadata: extending, how-to -->

### If it's a typed button (one-click, predictable output):

1. Add the verb to `ALLOWED_ADMIN_QUERIES` (for reads) or `ALLOWED_ADMIN_WRITES` (for writes) in `http_app.rb`.
2. Add a method to `CgminerCommander` — `def foo = fan_out_query(:foo)` for reads, or `def foo! = fan_out_write { |m| m.query(:foo) }` for writes.
3. Add the UI button to `views/manager/_admin.haml` and `views/miner/_admin.haml`.
4. Add a spec in `spec/cgminer_manager/cgminer_commander_spec.rb` or an integration spec in `spec/integration/admin_spec.rb`.

### If it's a hardware-tuning verb (must NOT target scope=all):

Add the verb to `SCOPE_RESTRICTED_VERBS` in `http_app.rb` *before* anything else. The server-side regex + UI disabling of the "all" scope both key off this list.

### If users should reach it only via raw RPC:

No code change needed. Users can POST `command=<verb>` to `/manager/admin/run`. The `ADMIN_RAW_COMMAND_PATTERN` (`/\A[a-z][a-z0-9_+]*\z/`) will accept any well-formed cgminer verb. Still consider scope restrictions.

## Ruby version support

<!-- metadata: runtime, compatibility -->

- **Minimum: Ruby 3.2.** Enforced by the gemspec. `Data.define` needs 3.2+; endless method defs need 3.0+.
- **CI-tested: 3.2 / 3.3 / 3.4** (must pass).
- **Best-effort: 4.0, head** via the nightly workflow.
- **Local dev pin:** `.ruby-version` = 4.0.2.

**Sharp edges:**
- `parallel` gem pinned `< 2.0` in the Gemfile because parallel 2.x requires Ruby 3.3. Transitive dep of RuboCop.
- Haml 6 (not 5) is required — the `html_safe?`-stamping helpers (`raw`, `html_safe`, `render_partial`) depend on Haml 6's escape semantics.

## Gotchas worth knowing up front

<!-- metadata: caveats, surprises -->

1. **Signal handlers must be installed before Puma boots, then reinstalled after.** Puma's `Launcher#run` calls `setup_signals` synchronously inside the Puma thread, overwriting any process-global SIGTERM/SIGINT traps. `Server#run` works around this by installing early, waiting on `@booted.pop` (signaled by `launcher.events.on_booted`), then reinstalling. Plus `raise_exception_on_sigterm false` to prevent Puma from raising SignalException inside its thread. If you change how Puma starts, re-verify SIGTERM routes through `@stop`.

2. **`CgminerApiClient::Miner#to_s` is monkey-patched at the top of `http_app.rb`** to return `"host:port"`. Upstream doesn't define it. If you see `Miner.to_s` returning something like `"#<CgminerApiClient::Miner:0x00007f...>"`, the monkey patch isn't loaded.

3. **`AdminAuth` reads env per-request, not at boot.** Intentional — lets dev harnesses toggle auth without restart. Empty strings = unset. If you want Basic Auth enabled, both `CGMINER_MANAGER_ADMIN_USER` and `CGMINER_MANAGER_ADMIN_PASSWORD` must be non-empty.

4. **`ConditionalAuthenticityToken` bypasses CSRF when Basic Auth passed.** Valid static Basic Auth is strictly stronger proof than session cookie + CSRF. This lets operators curl admin routes during incidents without scraping a token first. If you see admin POSTs inexplicably succeeding without a CSRF token, check whether Basic Auth is being sent.

5. **`SnapshotAdapter.sanitize_key` preserves `%`.** It does `downcase.tr(' ', '_').to_sym` only. `"Device Hardware%"` → `:'device_hardware%'`. That matches `cgminer_api_client::Miner#sanitized` (what the legacy partials expect), **not** monitor's Poller normalization (which maps `%` → `_pct` for time-series sample metadata). Don't "fix" the adapter to match the Poller; the partials will break.

6. **`settings.configured_miners` is eager-parsed at boot via `HttpApp.parse_miners_file`.** `Server#configure_http_app` runs it after setting the other Sinatra settings, so miners.yml shape errors (bad YAML, non-Array, entries missing `host`) surface as `ConfigError` → CLI exit 2 rather than as HTTP 500 on first request. Tests that mutate `miners_file` call `HttpApp.configure_for_test!(...)` to re-parse and re-populate the setting in one step.

7. **Raw admin RPC splits `args` on comma before escaping.** `CgminerCommander#raw!` does `args.to_s.split(',')` and passes the positional array to `Miner#query`. Commas inside argument values are not escapable through this form. Not a practical limitation for any real cgminer verb. Matches the README "raw RPC arg escaping caveat".

8. **Exit code 2 for config errors, not 78.** `cgminer_monitor` uses `78` (`EX_CONFIG`). Manager uses `2`. Not consistent; not worth fixing retroactively.

9. **`config/puma.rb` exists but is not used by `cgminer_manager run`.** `Server#build_puma_launcher` constructs its own `Puma::Configuration` inline. The file is there for direct `puma` / `rackup` invocations (dev harness, `config.ru`-based runs). Don't edit `config/puma.rb` expecting it to affect `run`.

10. **Session cookie is `Secure` only in production.** `Rack::Session::Cookie` gets `secure: settings.production`, and `secret: settings.session_secret || SecureRandom.hex(32)`, both captured via `HttpApp.install_middleware!` which `Server#configure_http_app` (and `HttpApp.configure_for_test!`) calls **after** the Sinatra settings are populated — so the operator's `CGMINER_MANAGER_SESSION_SECRET` actually reaches the middleware. Do not move the `use Rack::Session::Cookie` call into a class-body `configure do … end` block: Sinatra freezes `use` args at call time, and class-body eval runs before Server populates settings, which was the bug fixed in #10.

11. **Out-of-band git changes are normal.** Don't treat surprising git state (uncommitted changes you didn't make, an unfamiliar branch) as a tool malfunction — the maintainer works outside the assistant session.

## Release process

<!-- metadata: release, publishing -->

Not automated. On a clean `master`:

```sh
bundle exec rake                                     # must pass clean
# bump VERSION in lib/cgminer_manager/version.rb
# update CHANGELOG.md (Keep-a-Changelog format)
git commit -am "Release vX.Y.Z"
gem build cgminer_manager.gemspec                    # produces cgminer_manager-X.Y.Z.gem
gem push cgminer_manager-X.Y.Z.gem                   # requires 2FA (rubygems_mfa_required=true)
git tag vX.Y.Z
git push origin master vX.Y.Z
```

Docker image is not currently pushed by CI.

## Where to look for deeper context

<!-- metadata: doc-navigation -->

| Question | File |
|---|---|
| How do the classes relate architecturally? Why two upstreams? Why the signal dance? | [`docs/architecture.md`](docs/architecture.md) |
| What does each class do? | [`docs/components.md`](docs/components.md) |
| What's the route/CLI/env contract? What's in the structured log? | [`docs/interfaces.md`](docs/interfaces.md) |
| What's in a `ViewMiner` / `FleetWriteResult`? What errors can be raised? | [`docs/data_models.md`](docs/data_models.md) |
| How does a request flow? How does admin fan-out work? Release process? | [`docs/workflows.md`](docs/workflows.md) |
| Runtime deps? Why Ruby 3.2+? Why no Rails? | [`docs/dependencies.md`](docs/dependencies.md) |
| Known doc/code drift, unwired knobs, cleanup recommendations | [`docs/review_notes.md`](docs/review_notes.md) |
| Full knowledge-base index | [`docs/index.md`](docs/index.md) |
| User-facing docs | [`README.md`](README.md) |
| Release history, 1.0 rewrite, 1.1 UI restoration, 1.2 admin restoration | [`CHANGELOG.md`](CHANGELOG.md) |
| 0.x Rails → 1.0 Sinatra upgrade guide | [`MIGRATION.md`](MIGRATION.md) |
