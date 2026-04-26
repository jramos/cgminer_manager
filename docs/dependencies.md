# Dependencies

## Runtime dependencies

From the gemspec:

| Gem | Constraint | Purpose |
|---|---|---|
| `cgminer_api_client` | `~> 0.3` | TCP client for cgminer. Used by `CgminerCommander` and `PoolManager` for write-path RPC; used by `bin/cgminer_manager doctor` for per-miner TCP reachability checks. |
| `sinatra` | `~> 4.0` | HTTP app framework. `HttpApp < Sinatra::Base`. |
| `sinatra-contrib` | `~> 4.0` | Provides `Sinatra::ContentFor` helper used by the layout for block content. |
| `haml` | `~> 6.3` | Template engine. All views under `views/**/*.haml`. |
| `http` | `~> 5.2` | HTTP client gem for calling `cgminer_monitor`. Used via `MonitorClient`. (Not Faraday; not Net::HTTP.) |
| `puma` | `~> 6.4` | HTTP server. Embedded via `Puma::Configuration` + `Puma::Launcher`. |
| `rack-protection` | `~> 4.0` | CSRF + other Rack-level protections. `ConditionalAuthenticityToken` subclasses `Rack::Protection::AuthenticityToken`. |

Plus the Ruby stdlib pieces: `json`, `yaml`, `securerandom`, `digest`, `cgi`, `time`, plus `rack`, `rack/auth/basic`, `rack/session/cookie` (pulled in through the above).

**No MongoDB.** The 1.0 rewrite dropped Mongoid entirely. Manager does not talk to any database — it's a pure HTTP-and-templates service. Persistent state lives in monitor's MongoDB (accessed via monitor's HTTP API) and in cgminer itself (accessed via TCP).

**No asset pipeline.** No Sprockets, no Webpacker, no ESBuild. CSS and JS under `public/css/` and `public/js/` are served as-is by Puma. Cache-busting is done at the helper level via `?v=<VERSION>` appended to asset URLs (see `asset_url`, `stylesheet_link_tag`, `javascript_include_tag` helpers in `http_app.rb`).

## Dev dependencies

From `Gemfile`:

```ruby
group :development, :test do
  gem 'parallel', '< 2.0'
  gem 'rack-test',     '>= 2.1'
  gem 'rake',          '>= 13.2'
  gem 'rspec',         '>= 3.13'
  gem 'rubocop',       '>= 1.60'
  gem 'rubocop-rake',  '>= 0.6'
  gem 'rubocop-rspec', '>= 2.27'
  gem 'simplecov',     '>= 0.22'
  gem 'webmock',       '>= 3.23'
  gem 'cgminer_monitor',
      git: 'https://github.com/jramos/cgminer_monitor.git',
      tag: 'vX.Y.Z', require: false
end
```

| Gem | Used for |
|---|---|
| `parallel` | Pinned `< 2.0` because parallel 2.x requires Ruby >= 3.3 and we need to keep the Ruby 3.2 CI lane green. Transitive dep of `rubocop` / `rubocop-ast`. |
| `rack-test` | HTTP-level specs. Provides `Rack::Test::Methods` for making synthetic requests against `HttpApp` without booting Puma. |
| `rake` | Task runner. `Rakefile` defines `default: [rubocop, spec]`. |
| `rspec` | Test framework. Unit + integration. |
| `rubocop`, `rubocop-rake`, `rubocop-rspec` | Linter and plugins. |
| `simplecov` | Code coverage. Started in `spec_helper.rb` with coverage enforcement gated by `ENFORCE_COVERAGE=1` (set automatically by the rake task, not set when running filtered specs directly). |
| `webmock` | Stubs outbound HTTP calls to `cgminer_monitor`. See `spec/support/monitor_stubs.rb` for the helper module. |
| `cgminer_monitor` | CI-only dev dep, pinned by git tag. Ships its OpenAPI spec inside the gem at `lib/cgminer_monitor/openapi.yml`; `spec/contract/monitor_openapi_contract_spec.rb` loads it via `Gem::Specification.find_by_name` and asserts that every `/v2/*` envelope key `MonitorClient` reads is declared. Bumping the tag is a deliberate reviewable event — OpenAPI revisions surface as a pin bump PR. `require: false` keeps monitor out of manager's runtime autoload path; only the spec loader reaches into the gem dir. |

## Ruby version support

- **Minimum: Ruby 3.2.** Enforced by `spec.required_ruby_version = '>= 3.2'`.
  - `Data.define` (used in `Config`, `ViewMiner`, `FleetQueryResult`, `FleetWriteResult`, `PoolManager::MinerEntry`, `PoolManager::PoolActionResult`) requires 3.2+.
  - Endless method definitions (used throughout: `def method = ...`) require 3.0+.
- **CI-tested: 3.2, 3.3, 3.4.** Must-pass.
- **Best-effort: 4.0, head.** Via the nightly workflow (`.github/workflows/nightly.yml`). Allowed to fail.
- **Local dev pin:** `.ruby-version` = 4.0.2. Only affects contributors.

**Sharp edges:**
- `parallel` 2.x requires Ruby 3.3. Pinned to `< 2.0` in the Gemfile so Ruby 3.2 can still bundle.
- Haml 6 (not Haml 5) is required. Haml 5 and 6 have different internal APIs around `html_safe?` stamping — the `raw` and `html_safe` helpers in `http_app.rb` depend on Haml 6 semantics.

## CI matrix (`.github/workflows/ci.yml`)

Three jobs, plus a separate nightly:

### `lint`
- Single lane: Ruby 3.4 on `ubuntu-latest`.
- Runs `bundle exec rubocop`.
- Separated so rubocop failures don't block the test matrix.

### `test`
- Matrix: Ruby 3.2 / 3.3 / 3.4.
- Runs `bundle exec rspec --tag ~integration` (unit only).

### `integration`
- Single lane: Ruby 3.4.
- Runs `bundle exec rspec --tag integration`.
- Slower (HTTP + rack-test flows).

### `nightly` (separate workflow, `.github/workflows/nightly.yml`)
- Runs Ruby 4.0 and `head` lanes.
- Allowed to fail (marked experimental).
- Early-warning signal for upcoming Ruby versions.

Triggers: `push` and `pull_request` on `develop` or `master`. PR `concurrency:` configured to cancel in-progress runs on new pushes; push-to-branch runs let previous runs finish.

## External dependencies (not Ruby gems)

- **`cgminer_monitor`** — runtime requirement, 1.0+. Supplies the read-path data. The manager's `doctor` subcommand hard-fails if monitor is unreachable.
- **cgminer instances** — not strictly required for the manager to *boot*, but all write-path operations (pool mgmt, admin RPC) and the legacy `/api/v1/ping.json` endpoint need TCP reachability.
- **Docker** (optional dev) — `docker-compose.yml` wires manager + monitor + mongo. Not required if you want to run monitor and mongo separately.

## Dependency update strategy

No Dependabot or Renovate configured. Manual bumps when needed. Minimum-version constraints are intentionally loose (`rspec >= 3.13`, `sinatra ~> 4.0`, etc.) so Bundler resolves current versions without over-constraining consumers.

`Gemfile.lock` is `.gitignore`d — consumers generate their own.

## Why the dependency set is small

Intentional. The 0.x Rails-engine era had Rails 4.2, Mongoid 4, Thin, therubyracer, Sprockets, jquery-rails, sass-rails, coffee-rails, Bootstrap via Sass. The 1.0 rewrite deleted all of that in favor of hand-written HAML + vanilla JS + Chart.js served from `public/`. The net result:

- No asset-pipeline maintenance burden.
- No Rails upgrade cadence.
- No Mongoid-Rails version compatibility matrix.
- Fewer transitive deps → faster `bundle install`, smaller container images.

The trade-off is that a few Rails conveniences (URL helpers, asset helpers, `time_ago_in_words`) had to be hand-rolled in `http_app.rb` helpers. Those are stable now; don't reach for more Rails-like sugar without a reason.
