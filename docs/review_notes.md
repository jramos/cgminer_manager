# Review Notes

Self-audit of the documentation set. Honest list of what I couldn't fully verify, known gaps in the code, and the items I'd flag for cleanup work. Read this before trusting a confident-sounding claim elsewhere in `docs/`.

## Consistency check

I cross-referenced the following claims across files and found no contradictions:

| Claim | Asserted in | Verified |
|---|---|---|
| Read path goes through `cgminer_monitor` over HTTP; write path goes direct to cgminer via `cgminer_api_client` over TCP | `codebase_info.md`, `architecture.md`, `components.md`, `workflows.md`, `interfaces.md` | consistent |
| `Config` is an immutable `Data.define` | `codebase_info.md`, `architecture.md`, `components.md`, `data_models.md` | consistent |
| `HttpApp` state lives in Sinatra settings (monitor_url, miners_file, stale_threshold_seconds, pool_thread_cap, monitor_timeout_ms, session_secret, production, configured_miners) set by `Server#configure_http_app` | `codebase_info.md`, `architecture.md`, `components.md` | consistent |
| CLI exit codes 0 / 1 / 2 / 64 | `interfaces.md`, `components.md`, `workflows.md` | consistent |
| `Data.define` value objects for `ViewMiner`, `FleetQueryResult`, `FleetWriteResult`, `PoolActionResult` | `codebase_info.md`, `components.md`, `data_models.md` | consistent |
| Admin surface is ergonomic-vs-defensive (allowlist is UI, defense is Basic Auth + scope restrictions + audit logging) | `architecture.md`, `components.md`, `interfaces.md` | consistent |
| Signal-handler reinstall dance around Puma's `setup_signals` | `architecture.md`, `components.md`, `workflows.md` | consistent |

Nothing contradictory. If later edits introduce drift, re-run this section.

## Completeness gaps (in the code)

(Gaps 1, 3, 4, and 10 from the original pass have been addressed; see `CHANGELOG.md` Unreleased section. Gap 8 was factually wrong — `spec/integration/full_boot_spec.rb` does spawn the real binary, bind a listener, send SIGTERM, and assert on exit 0 — removed.)

### 1. `2` vs `78` for `EX_CONFIG`

`CLI#run` maps `ConfigError` to exit code `2`. `cgminer_monitor` uses `78` (`EX_CONFIG` per sysexits(3)) for the same failure. The convention across the three repos isn't consistent. Low-value to fix — operators don't usually key off these codes — but if you're already editing `cli.rb`, it's a one-line change to standardize.

### 2. Dashboard and per-miner routes spawn thread pools per request

`ViewModels.fetch_snapshots_for` and `FleetBuilders.commander_for_all` both spawn a fresh pool of threads for each request. Under load (dashboard auto-refresh at low interval, multiple operators refreshing, Prometheus scraping `/healthz` frequently) this creates thread churn.

**Not a problem at current scale** (< 10 miners, < 10 operators), but if usage grows, consider a persistent worker pool per `HttpApp` instance. Documenting for future-you.

### 3. No OpenAPI spec (unlike monitor)

`cgminer_monitor` has an `openapi.yml` and a CI parity check that breaks the build when routes and spec drift. Manager has no OpenAPI spec. All 14 routes are documented here in `interfaces.md`, but there's no machine-checked parity.

**If we want one:** follow monitor's pattern — add `lib/cgminer_manager/openapi.yml`, serve it at `/openapi.yml`, add a `spec/openapi_consistency_spec.rb`, add a CI job. Worth doing if a third party needs to build against the API; overkill for internal use.

### 4. Admin audit log: `session_id_hash` truncation is cosmetic

`AdminLogging.session_id_hash` returns `Digest::SHA256.hexdigest(sid)[0..11]` — 12 hex chars, 48 bits. Collisions are extraordinarily unlikely in a short log window, but not zero. Documenting because the comment in the code doesn't explain the trade-off: 12 chars is "short enough to eyeball across log entries, long enough that correlating two entries by the hash isn't attacker-useful even if the session ID is long-lived."

### 5. `raw!` comma-split is documented but error-handling isn't

`CgminerCommander#raw!` does `args.to_s.split(',')` and passes the array positionally. If an argument *has* to contain a comma, there's no escape. The README's "Raw RPC arg escaping caveat" section documents this at a policy level, but there's no defensive behavior in the code — a would-be-escaped comma goes through as a split delimiter. Matches cgminer's own arg-passing semantics; flagged because it's the kind of thing someone might "fix" without understanding why it's a deliberate pass-through.

## Gaps in these docs

- I didn't count lines in each partial or enumerate every helper method. The "~650 LOC" figure for `http_app.rb` (post view-model split) is from `wc -l`, rounded.
- I didn't exhaustively trace every CSS/JS file under `public/`. Chart.js lives there; the exact version isn't pinned here.
- The CI workflow section in `dependencies.md` accurately describes `ci.yml` but only skims `nightly.yml` (I didn't read it end-to-end).
- The screenshot harness in `dev/screenshots/` is mentioned but not deeply documented — its own README is authoritative.

## Language and tooling limitations

- **Ruby-only.** No FFI, no native extensions.
- **macOS and Linux only in practice.** Windows is untested.
- **CI runs on `ubuntu-latest` only** (currently Ubuntu 24.04).
- **No `brakeman`.** Would be a reasonable addition given the admin surface; not wired today.

## Recommendations

Medium effort, possibly worth it:
1. Add `brakeman` to the CI lint job. The admin surface is the likely beneficiary.
2. Add an OpenAPI spec + parity check (match monitor's pattern). Only if a third party consumes the API.
3. Standardize config-error exit code to `78` across the three repos.

Higher effort, defer:
4. Persistent worker pool for dashboard snapshot fan-out. Only if load makes it necessary.

## How I validated

- Read every file under `lib/`, `bin/`, `spec/support/`, `config/`, `.github/workflows/`, plus `Gemfile`, the gemspec, `Rakefile`, `.rubocop.yml`, `.rspec`, `Dockerfile`, `docker-compose.yml`, `config.ru`, `config/puma.rb`, `miners.yml.example`, README, CHANGELOG, MIGRATION.
- Did not exhaustively read every `views/**/*.haml` file; sampled enough to understand the shape and confirm the claims about partial structure.
- Did not read the integration specs' full bodies; enumerated them and spot-checked a few for shape.
- Did not run the test suite as part of writing these docs. Claims like "passes cleanly" are based on reading the specs + CI config, not a pass/fail run (though `bundle exec rake` will be run before the commit that lands this doc set).
- Did not verify every log event name by grepping — relied on the source-code context for each claim. If a new log event is added, it'll need to land in `interfaces.md` by hand.
