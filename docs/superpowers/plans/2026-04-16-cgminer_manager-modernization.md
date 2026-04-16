# cgminer_manager Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `cgminer_manager` from Rails 4.2 + Mongoid 4 to a standalone Sinatra + Puma service matching the modernized `cgminer_monitor` shape, consuming monitor's `/v2/*` HTTP API for display data and keeping `cgminer_api_client` 0.3.x for the command plane.

**Architecture:** One Sinatra `HttpApp` mounted by a Puma-driven `Server`; a `MonitorClient` for the read plane (HTTP to `cgminer_monitor`); a `PoolManager` service object for the command plane (TCP via `cgminer_api_client`); typed `PoolActionResult` with three-state per-step status. No MongoDB in this service.

**Tech Stack:** Ruby 3.2+ (`.ruby-version` 4.0.2), Sinatra, Puma, `http` gem, HAML, `cgminer_api_client` ~> 0.3, RSpec, WebMock, SimpleCov, RuboCop, GitHub Actions, Docker.

**Reference spec:** `docs/superpowers/specs/2026-04-16-cgminer_manager-modernization-design.md`.

**Assumed before this plan starts:** Phase -1 of the spec — the `cgminer_monitor` companion PR adding `/v2/graph_data/{hardware_error,pool_stale,pool_rejected,device_rejected}` and any additional metric endpoints — has landed and been released as a tagged version of `cgminer_monitor`. The version tag is referenced by this plan as `MIN_MONITOR_VERSION`. Task 4.0 below explicitly preflight-checks this.

**Judgment calls baked into this plan** (recorded for future auditability):
- **Coverage floor: 80%** on `lib/`. Aggressive for a Sinatra+HAML app without a full UI test suite; can be raised later as more specs land.
- **CI required matrix: Ruby 3.2 / 3.3 / 3.4.** Ruby 4.0 and `head` run in a separate optional nightly workflow, not blocking PRs.
- **Rails-isms in views: rewritten, not shimmed.** The two embedded `Time.zone.now` + `Rails.application.class.parent_name` call sites are rewritten to plain Ruby. Cleaner than growing the shim surface.
- **`/api/v1/ping.json` uses `Miner#available?` directly**, not `MinerPool`. The `MinerPool` constructor hardcodes `config/miners.yml` relative to CWD, which breaks test isolation; direct `Miner` iteration is simpler and testable.
- **`v0-legacy` tag is placed on the current `develop` HEAD before this plan's Phase 0 runs** (so it points at a commit where `rails server` still actually works). Phase 7 pushes that tag to the remote; it does not create it mid-branch.
- **`app/views/manager/_admin.haml`, `app/views/miner/_admin.haml`, `app/views/shared/_run.haml`, and `app/views/shared/run/` are dropped entirely** in the port. They are UI wrappers around `/manager/run` and `/miner/:id/run`, which the spec cuts (§ 7.1). MIGRATION.md documents this.

---

## File Structure (final target)

```
cgminer_manager/
├── bin/cgminer_manager                       # CLI entry
├── cgminer_manager.gemspec                   # gemspec (metadata + required_ruby_version)
├── Gemfile                                   # runtime + dev deps
├── Gemfile.lock                              # committed
├── Rakefile                                  # rspec + rubocop default task
├── .ruby-version                             # 4.0.2
├── .rubocop.yml                              # ported/tuned from monitor
├── .github/workflows/ci.yml                  # lint / test matrix / integration
├── Dockerfile                                # multi-stage
├── docker-compose.yml                        # manager + monitor + mongo
├── README.md                                 # rewritten
├── MIGRATION.md                              # Rails → Sinatra operator guide
├── CHANGELOG.md                              # 1.0.0 entry
├── config/
│   ├── miners.yml.example                    # unchanged shape
│   └── puma.rb                               # Puma config
├── lib/cgminer_manager.rb                    # top-level require entry
├── lib/cgminer_manager/
│   ├── version.rb                            # VERSION constant
│   ├── errors.rb                             # Error / ConfigError / MonitorError / PoolManagerError
│   ├── config.rb                             # Data.define value object
│   ├── logger.rb                             # JSON/text, thread-safe
│   ├── monitor_client.rb                     # HTTP client for monitor /v2/*
│   ├── pool_manager.rb                       # service object + PoolActionResult
│   ├── http_app.rb                           # Sinatra::Base subclass
│   ├── server.rb                             # Puma launcher + signal handling
│   └── cli.rb                                # verb dispatcher
├── views/
│   ├── layouts/application.haml              # root layout + CSRF meta + asset tags
│   ├── layouts/_header.haml
│   ├── layouts/_footer.haml
│   ├── manager/index.haml                    # dashboard
│   ├── manager/_summary.haml
│   ├── manager/_admin.haml
│   ├── manager/_miner_pool.haml
│   ├── miner/show.haml                       # per-miner page
│   ├── miner/_summary.haml
│   ├── miner/_stats.haml
│   ├── miner/_admin.haml
│   ├── miner/_pools.haml
│   ├── miner/_devices.haml
│   ├── shared/_manage_pools.haml
│   ├── shared/_miner_devices_table.haml
│   ├── shared/_miner_hashrate_table.haml
│   ├── shared/_warnings.haml
│   └── shared/graphs/
│       ├── _hashrate.haml
│       ├── _temperature.haml
│       ├── _availability.haml
│       ├── _hardware_error.haml
│       ├── _pool_rejected.haml
│       ├── _pool_stale.haml
│       └── _device_rejected.haml
├── public/
│   ├── js/
│   │   ├── jquery-3.6.0.min.js
│   │   ├── jquery.cookie.js
│   │   ├── chart.min.js
│   │   ├── manager.js
│   │   ├── miner.js
│   │   ├── graph.js
│   │   ├── audio.js
│   │   └── config.js
│   ├── css/
│   │   ├── application.css
│   │   ├── base.css
│   │   ├── manager.css
│   │   ├── miner.css
│   │   └── mobile.css
│   └── audio/                                # (if audio assets exist; otherwise omit)
└── spec/
    ├── spec_helper.rb
    ├── .rspec                                # --color --format doc
    ├── fixtures/
    │   └── monitor/
    │       ├── miners.json
    │       ├── summary.json
    │       ├── devices.json
    │       ├── pools.json
    │       ├── stats.json
    │       ├── graph_data_hashrate.json
    │       └── healthz.json
    ├── support/
    │   ├── fake_cgminer.rb                   # ported from cgminer_api_client
    │   ├── cgminer_fixtures.rb               # ported from cgminer_api_client
    │   └── monitor_stubs.rb                  # WebMock helpers
    ├── cgminer_manager/
    │   ├── version_spec.rb
    │   ├── errors_spec.rb
    │   ├── config_spec.rb
    │   ├── logger_spec.rb
    │   ├── monitor_client_spec.rb
    │   ├── pool_manager_spec.rb
    │   └── cli_spec.rb
    └── integration/
        ├── dashboard_spec.rb
        ├── miner_page_spec.rb
        ├── graph_data_spec.rb
        ├── healthz_spec.rb
        ├── staleness_spec.rb
        ├── ping_spec.rb
        ├── pool_management_spec.rb
        └── full_boot_spec.rb
```

Files that remain in the repo but are NOT touched by v1.0.0 (left in place for v0-legacy rollback per § 18 of the spec, removed in a follow-up PR):

```
app/                                          # old Rails app
config/application.rb, config/environments/, config/routes.rb,
config/boot.rb, config/environment.rb         # Rails boot chain
lib/tasks/                                    # Rails rake tasks
test/                                         # empty Rails test stubs
```

---

## Pre-Phase 0 — Tag `v0-legacy`

This MUST happen on `develop` before the modernization branch is cut, so that `v0-legacy` points at a commit where the old Rails app actually boots (`bundle install && rails server`). Tagging mid-branch would land on a commit where `Gemfile` has already dropped Rails.

### Task -1.1: Create `v0-legacy` tag on current develop HEAD

- [ ] **Step 1: Verify you're on develop with a clean tree**

```bash
cd /Users/justin/src/jramos/cgminer_manager
git checkout develop
git pull --ff-only
git status
```

Expected: `On branch develop` / `nothing to commit, working tree clean`.

- [ ] **Step 2: Create the annotated tag**

```bash
git tag -a v0-legacy -m "Last commit where the Rails-era app still boots (pre-Sinatra port)"
```

- [ ] **Step 3: Push the tag**

```bash
git push origin v0-legacy
```

Task 7.1 later references this tag; it does NOT re-create it.

## Phase 0 — Prep

### Task 0.1: Branch + CI scaffolding

**Files:**
- Modify: (git branch only)
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/nightly.yml`
- Create: `.ruby-version`

- [ ] **Step 1: Create feature branch**

```bash
git checkout -b modernize/sinatra-port
```

- [ ] **Step 2: Add `.ruby-version`**

```bash
echo "4.0.2" > .ruby-version
```

- [ ] **Step 3: Add empty CI workflow that runs against an empty test suite**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [develop, master]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true
      - run: bundle exec rubocop

  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ['3.2', '3.3', '3.4']
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rspec --tag ~integration

  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true
      - run: bundle exec rspec --tag integration
```

- [ ] **Step 4: Write `.github/workflows/nightly.yml`** — optional Ruby 4.0 / head matrix, not required for PRs

```yaml
name: Nightly (optional)

on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ['4.0', 'head']
    continue-on-error: true
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rspec
```

- [ ] **Step 5: Commit**

```bash
git add .ruby-version .github/workflows/ci.yml .github/workflows/nightly.yml
git commit -m "chore: add Ruby version pin and CI scaffolding (3.2-3.4 required, 4.0/head nightly)"
```

### Task 0.2: Gemfile + gemspec skeleton

**Files:**
- Create: `cgminer_manager.gemspec`
- Modify: `Gemfile` (replace entirely)
- Delete: `Gemfile.lock` (regenerate after)

- [ ] **Step 1: Write new gemspec**

Create `cgminer_manager.gemspec`:

```ruby
# frozen_string_literal: true

require_relative 'lib/cgminer_manager/version'

Gem::Specification.new do |spec|
  spec.name        = 'cgminer_manager'
  spec.version     = CgminerManager::VERSION
  spec.authors     = ['Justin Ramos']
  spec.email       = ['justin@southernmadelabs.com']
  spec.summary     = 'Web UI for managing cgminer-based mining rigs'
  spec.description = 'Sinatra service that displays data from cgminer_monitor and issues ' \
                     'pool-management commands to cgminer instances via cgminer_api_client.'
  spec.homepage    = 'https://github.com/jramos/cgminer_manager'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir['lib/**/*', 'views/**/*', 'public/**/*', 'bin/*',
                   'config/**/*.example', 'config/puma.rb',
                   'README.md', 'MIGRATION.md', 'CHANGELOG.md', 'LICENSE'].reject { |f| File.directory?(f) }
  spec.bindir      = 'bin'
  spec.executables = ['cgminer_manager']

  spec.metadata = {
    'source_code_uri'       => spec.homepage,
    'changelog_uri'         => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'cgminer_api_client', '~> 0.3'
  spec.add_dependency 'haml', '~> 6.3'
  spec.add_dependency 'http', '~> 5.2'
  spec.add_dependency 'puma', '~> 6.4'
  spec.add_dependency 'rack-protection', '~> 4.0'
  spec.add_dependency 'sinatra', '~> 4.0'
  spec.add_dependency 'sinatra-contrib', '~> 4.0' # content_for, namespace, etc.
end
```

- [ ] **Step 2: Rewrite Gemfile**

Replace `Gemfile` entirely with:

```ruby
# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'rake', '>= 13.2'
  gem 'rspec', '>= 3.13'
  gem 'rubocop', '>= 1.60'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec', '>= 2.27'
  gem 'simplecov', '>= 0.22'
  gem 'webmock', '>= 3.23'
  gem 'rack-test', '>= 2.1'
end
```

- [ ] **Step 3: Create minimum `lib/cgminer_manager/version.rb` so gemspec can load**

```ruby
# frozen_string_literal: true

module CgminerManager
  VERSION = '1.0.0.pre'
end
```

- [ ] **Step 4: Regenerate lockfile**

```bash
rm -f Gemfile.lock
bundle install
```

Expected: Bundler resolves all new deps; no errors.

- [ ] **Step 5: Commit**

```bash
git add cgminer_manager.gemspec Gemfile Gemfile.lock lib/cgminer_manager/version.rb
git commit -m "chore: introduce gemspec and Sinatra-era Gemfile"
```

### Task 0.3: RuboCop + Rake + spec_helper

**Files:**
- Create: `.rubocop.yml`
- Create: `Rakefile`
- Create: `spec/.rspec`
- Create: `spec/spec_helper.rb`

- [ ] **Step 1: Write `.rubocop.yml` tuned from monitor**

```yaml
AllCops:
  TargetRubyVersion: 3.2
  NewCops: enable
  Exclude:
    - 'vendor/**/*'
    - 'tmp/**/*'
    - 'app/**/*'        # legacy Rails tree (removed in follow-up PR)
    - 'config/application.rb'
    - 'config/environment.rb'
    - 'config/environments/**/*'
    - 'config/routes.rb'
    - 'config/boot.rb'
    - 'lib/tasks/**/*'
    - 'test/**/*'

require:
  - rubocop-rake
  - rubocop-rspec

Style/Documentation:
  Enabled: false

Style/FrozenStringLiteralComment:
  EnforcedStyle: always

Metrics/BlockLength:
  Exclude:
    - 'spec/**/*'
    - 'lib/cgminer_manager/http_app.rb'

Metrics/MethodLength:
  Max: 25

Metrics/ClassLength:
  Max: 250

Metrics/AbcSize:
  Max: 25

RSpec/ExampleLength:
  Max: 20

RSpec/MultipleExpectations:
  Max: 5

RSpec/NestedGroups:
  Max: 4

RSpec/MessageChain:
  Enabled: false
```

- [ ] **Step 2: Write `Rakefile`**

```ruby
# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task default: %i[rubocop spec]
```

- [ ] **Step 3: Write `.rspec`**

Create `.rspec` at repo root:

```
--color
--require spec_helper
--format documentation
```

- [ ] **Step 4: Write `spec/spec_helper.rb`**

```ruby
# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/'
  add_filter '/app/'       # legacy Rails tree excluded from coverage math
  minimum_coverage line: 80
end

ENV['RACK_ENV'] ||= 'test'

require 'cgminer_manager'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end
  config.order = :random
  Kernel.srand config.seed

  config.define_derived_metadata(file_path: %r{/spec/integration/}) do |meta|
    meta[:integration] = true
  end
end
```

- [ ] **Step 5: Write placeholder `lib/cgminer_manager.rb`**

```ruby
# frozen_string_literal: true

require_relative 'cgminer_manager/version'
```

- [ ] **Step 6: Run `rake` to confirm green on empty suite**

```bash
bundle exec rake
```

Expected: 0 examples, 0 failures; RuboCop passes or emits only style suggestions on scaffolding.

- [ ] **Step 7: Commit**

```bash
git add .rubocop.yml Rakefile .rspec spec/spec_helper.rb lib/cgminer_manager.rb
git commit -m "chore: rubocop + rspec scaffolding, empty green suite"
```

---

## Phase 1 — Library core: version, errors, config, logger

### Task 1.1: `version_spec.rb`

**Files:**
- Create: `spec/cgminer_manager/version_spec.rb`
- Modify: `lib/cgminer_manager/version.rb`

- [ ] **Step 1: Write failing test**

`spec/cgminer_manager/version_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe CgminerManager do
  describe 'VERSION' do
    it 'is a non-empty string' do
      expect(described_class::VERSION).to be_a(String)
      expect(described_class::VERSION).not_to be_empty
    end

    it 'follows semver-ish shape' do
      expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+(\.\w+)?\z/)
    end
  end
end
```

- [ ] **Step 2: Run, confirm pass (version already exists from Task 0.2)**

```bash
bundle exec rspec spec/cgminer_manager/version_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add spec/cgminer_manager/version_spec.rb
git commit -m "test: lock VERSION constant shape"
```

### Task 1.2: `errors.rb` — exception hierarchy

**Files:**
- Create: `lib/cgminer_manager/errors.rb`
- Create: `spec/cgminer_manager/errors_spec.rb`
- Modify: `lib/cgminer_manager.rb` (require errors)

- [ ] **Step 1: Write failing test**

`spec/cgminer_manager/errors_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe CgminerManager do
  describe 'error hierarchy' do
    it 'defines a top-level Error' do
      expect(CgminerManager::Error.ancestors).to include(StandardError)
    end

    it 'defines ConfigError < Error' do
      expect(CgminerManager::ConfigError.ancestors).to include(CgminerManager::Error)
    end

    it 'defines MonitorError < Error' do
      expect(CgminerManager::MonitorError.ancestors).to include(CgminerManager::Error)
    end

    it 'defines MonitorError::ConnectionError' do
      expect(CgminerManager::MonitorError::ConnectionError.ancestors)
        .to include(CgminerManager::MonitorError)
    end

    it 'defines MonitorError::ApiError' do
      expect(CgminerManager::MonitorError::ApiError.ancestors)
        .to include(CgminerManager::MonitorError)
    end

    it 'defines PoolManagerError::DidNotConverge < Error' do
      expect(CgminerManager::PoolManagerError::DidNotConverge.ancestors)
        .to include(CgminerManager::Error)
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bundle exec rspec spec/cgminer_manager/errors_spec.rb
```

Expected: NameError on `CgminerManager::Error`.

- [ ] **Step 3: Write `lib/cgminer_manager/errors.rb`**

```ruby
# frozen_string_literal: true

module CgminerManager
  class Error < StandardError; end
  class ConfigError < Error; end

  class MonitorError < Error
    class ConnectionError < MonitorError; end
    class ApiError < MonitorError
      attr_reader :status, :body

      def initialize(msg = nil, status: nil, body: nil)
        super(msg)
        @status = status
        @body = body
      end
    end
  end

  module PoolManagerError
    class DidNotConverge < Error; end
  end
end
```

- [ ] **Step 4: Require errors from top-level module**

Edit `lib/cgminer_manager.rb`:

```ruby
# frozen_string_literal: true

require_relative 'cgminer_manager/version'
require_relative 'cgminer_manager/errors'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/errors_spec.rb
```

Expected: 6 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/errors.rb lib/cgminer_manager.rb spec/cgminer_manager/errors_spec.rb
git commit -m "feat(errors): add typed error hierarchy"
```

### Task 1.3: `config.rb` — `Data.define` value object

**Files:**
- Create: `lib/cgminer_manager/config.rb`
- Create: `spec/cgminer_manager/config_spec.rb`
- Modify: `lib/cgminer_manager.rb` (require config)

- [ ] **Step 1: Write failing test**

`spec/cgminer_manager/config_spec.rb`:

```ruby
# frozen_string_literal: true

require 'tmpdir'

RSpec.describe CgminerManager::Config do
  let(:miners_file) do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  let(:env_base) do
    {
      'CGMINER_MONITOR_URL' => 'http://localhost:9292',
      'MINERS_FILE' => miners_file,
      'SESSION_SECRET' => 'x' * 64
    }
  end

  describe '.from_env' do
    it 'parses a fully-populated env into a Config' do
      config = described_class.from_env(env_base)

      expect(config.monitor_url).to eq('http://localhost:9292')
      expect(config.miners_file).to eq(miners_file)
      expect(config.port).to eq(3000)
      expect(config.bind).to eq('127.0.0.1')
      expect(config.log_format).to eq('text')
      expect(config.log_level).to eq('info')
      expect(config.stale_threshold_seconds).to eq(300)
      expect(config.shutdown_timeout).to eq(10)
    end

    it 'raises ConfigError when CGMINER_MONITOR_URL missing' do
      expect { described_class.from_env(env_base.merge('CGMINER_MONITOR_URL' => nil).compact) }
        .to raise_error(CgminerManager::ConfigError, /CGMINER_MONITOR_URL/)
    end

    it 'raises ConfigError when miners file missing' do
      expect { described_class.from_env(env_base.merge('MINERS_FILE' => '/no/such/file')) }
        .to raise_error(CgminerManager::ConfigError, /miners_file/)
    end

    it 'raises ConfigError when log_level invalid' do
      expect { described_class.from_env(env_base.merge('LOG_LEVEL' => 'trace')) }
        .to raise_error(CgminerManager::ConfigError, /log_level/)
    end

    it 'raises ConfigError when SESSION_SECRET unset in production' do
      env = env_base.merge('RACK_ENV' => 'production').tap { |h| h.delete('SESSION_SECRET') }
      expect { described_class.from_env(env) }
        .to raise_error(CgminerManager::ConfigError, /SESSION_SECRET/)
    end

    it 'accepts numeric env values and coerces them' do
      config = described_class.from_env(env_base.merge(
                                          'PORT' => '8080',
                                          'STALE_THRESHOLD_SECONDS' => '600'
                                        ))
      expect(config.port).to eq(8080)
      expect(config.stale_threshold_seconds).to eq(600)
    end

    it 'raises ConfigError when PORT is not an integer' do
      expect { described_class.from_env(env_base.merge('PORT' => 'abc')) }
        .to raise_error(CgminerManager::ConfigError, /PORT/)
    end
  end

  describe '#load_miners' do
    it 'yields [host, port] pairs' do
      config = described_class.from_env(env_base)
      expect(config.load_miners).to eq([['127.0.0.1', 4028]])
    end

    it 'defaults port to 4028 if missing in YAML' do
      File.write(miners_file, "- host: 10.0.0.5\n")
      config = described_class.from_env(env_base)
      expect(config.load_miners).to eq([['10.0.0.5', 4028]])
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bundle exec rspec spec/cgminer_manager/config_spec.rb
```

Expected: NameError on `CgminerManager::Config`.

- [ ] **Step 3: Write `lib/cgminer_manager/config.rb`**

```ruby
# frozen_string_literal: true

require 'yaml'
require 'securerandom'

module CgminerManager
  Config = Data.define(
    :monitor_url,
    :miners_file,
    :port, :bind,
    :log_format, :log_level,
    :session_secret,
    :stale_threshold_seconds,
    :shutdown_timeout,
    :monitor_timeout,
    :pool_thread_cap,
    :rack_env
  ) do
    def validate!
      raise ConfigError, 'CGMINER_MONITOR_URL is required' if monitor_url.nil? || monitor_url.empty?
      raise ConfigError, "miners_file not found: #{miners_file}" unless File.exist?(miners_file)
      raise ConfigError, 'log_format must be json or text' unless %w[json text].include?(log_format)
      raise ConfigError, 'invalid log_level' unless %w[debug info warn error].include?(log_level)

      self
    end

    def load_miners
      YAML.safe_load_file(miners_file).map { |m| [m['host'], m['port'] || 4028] }
    end

    def production?
      rack_env == 'production'
    end
  end

  class << Config
    def from_env(env = ENV)
      rack_env = env.fetch('RACK_ENV', 'development')
      new(
        monitor_url: env['CGMINER_MONITOR_URL'],
        miners_file: env.fetch('MINERS_FILE', 'config/miners.yml'),
        port: parse_int(env, 'PORT', '3000'),
        bind: env.fetch('BIND', '127.0.0.1'),
        log_format: env.fetch('LOG_FORMAT', rack_env == 'production' ? 'json' : 'text'),
        log_level: env.fetch('LOG_LEVEL', 'info'),
        session_secret: resolve_session_secret(env, rack_env),
        stale_threshold_seconds: parse_int(env, 'STALE_THRESHOLD_SECONDS', '300'),
        shutdown_timeout: parse_int(env, 'SHUTDOWN_TIMEOUT', '10'),
        monitor_timeout: parse_int(env, 'MONITOR_TIMEOUT_MS', '2000'),
        pool_thread_cap: parse_int(env, 'POOL_THREAD_CAP', '8'),
        rack_env: rack_env
      ).validate!
    end

    private

    def parse_int(env, key, default)
      Integer(env.fetch(key, default))
    rescue ArgumentError
      raise ConfigError, "#{key} must be an integer, got: #{env[key].inspect}"
    end

    def resolve_session_secret(env, rack_env)
      secret = env['SESSION_SECRET']
      return secret if secret && !secret.empty?
      raise ConfigError, 'SESSION_SECRET is required in production' if rack_env == 'production'

      warn '[cgminer_manager] SESSION_SECRET unset; generating ephemeral secret (dev only)'
      SecureRandom.hex(32)
    end
  end
end
```

- [ ] **Step 4: Require config from top-level module**

Edit `lib/cgminer_manager.rb`:

```ruby
# frozen_string_literal: true

require_relative 'cgminer_manager/version'
require_relative 'cgminer_manager/errors'
require_relative 'cgminer_manager/config'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/config_spec.rb
```

Expected: 8 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/config.rb lib/cgminer_manager.rb spec/cgminer_manager/config_spec.rb
git commit -m "feat(config): env-driven Data.define value object"
```

### Task 1.4: `logger.rb` — structured JSON/text logger

**Files:**
- Create: `lib/cgminer_manager/logger.rb`
- Create: `spec/cgminer_manager/logger_spec.rb`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write failing test**

`spec/cgminer_manager/logger_spec.rb`:

```ruby
# frozen_string_literal: true

require 'stringio'
require 'json'

RSpec.describe CgminerManager::Logger do
  let(:io) { StringIO.new }

  before do
    described_class.output = io
    described_class.format = 'json'
    described_class.level  = 'info'
  end

  describe '.info' do
    it 'writes one JSON line with level, ts, and the provided fields' do
      described_class.info(event: 'ready', pid: 123)
      entry = JSON.parse(io.string.lines.first, symbolize_names: true)

      expect(entry[:level]).to eq('info')
      expect(entry[:event]).to eq('ready')
      expect(entry[:pid]).to eq(123)
      expect(entry[:ts]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe '.debug' do
    context 'when level=info' do
      it 'does not emit' do
        described_class.debug(event: 'noise')
        expect(io.string).to eq('')
      end
    end

    context 'when level=debug' do
      it 'does emit' do
        described_class.level = 'debug'
        described_class.debug(event: 'noise')
        expect(io.string).not_to be_empty
      end
    end
  end

  describe 'text format' do
    before { described_class.format = 'text' }

    it 'formats as "ts LEVEL event k=v k=v"' do
      described_class.info(event: 'ready', pid: 123)
      expect(io.string).to match(/\A\S+ INFO ready pid=123/)
    end
  end

  describe 'thread safety' do
    it 'does not interleave lines under concurrent writers' do
      described_class.format = 'json'
      threads = 20.times.map do |i|
        Thread.new { 50.times { described_class.info(event: 'tick', i: i) } }
      end
      threads.each(&:join)

      lines = io.string.lines
      expect(lines.size).to eq(20 * 50)
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bundle exec rspec spec/cgminer_manager/logger_spec.rb
```

Expected: NameError on `CgminerManager::Logger`.

- [ ] **Step 3: Write `lib/cgminer_manager/logger.rb`** (structurally identical to monitor's; see `cgminer_monitor/lib/cgminer_monitor/logger.rb`)

```ruby
# frozen_string_literal: true

require 'json'
require 'time'

module CgminerManager
  module Logger
    LEVELS = { 'debug' => 0, 'info' => 1, 'warn' => 2, 'error' => 3 }.freeze

    @output = $stdout
    @format = 'json'
    @level  = 'info'
    @mutex  = Mutex.new

    class << self
      attr_accessor :output, :format, :level

      def info(**fields)  = log('info', fields)
      def warn(**fields)  = log('warn', fields)
      def error(**fields) = log('error', fields)
      def debug(**fields) = log('debug', fields)

      private

      def log(level_name, fields)
        return unless LEVELS.fetch(level_name, 0) >= LEVELS.fetch(@level, 1)

        entry = { ts: Time.now.utc.iso8601(3), level: level_name }.merge(fields)

        line = case @format
               when 'text' then format_text(entry)
               else JSON.generate(entry)
               end

        @mutex.synchronize { @output.puts(line) }
      end

      def format_text(entry)
        ts = entry.delete(:ts)
        level = entry.delete(:level)
        event = entry.delete(:event)
        kvs = entry.map { |k, v| "#{k}=#{v}" }.join(' ')
        [ts, level.upcase, event, kvs].compact.reject(&:empty?).join(' ')
      end
    end
  end
end
```

- [ ] **Step 4: Require logger from top-level module**

Edit `lib/cgminer_manager.rb`:

```ruby
# frozen_string_literal: true

require_relative 'cgminer_manager/version'
require_relative 'cgminer_manager/errors'
require_relative 'cgminer_manager/config'
require_relative 'cgminer_manager/logger'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/logger_spec.rb
```

Expected: 5 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/logger.rb lib/cgminer_manager.rb spec/cgminer_manager/logger_spec.rb
git commit -m "feat(logger): structured JSON/text logger"
```

---

## Phase 2 — Read plane: `MonitorClient`

### Task 2.1: Monitor fixture JSON

**Files:**
- Create: `spec/fixtures/monitor/miners.json`
- Create: `spec/fixtures/monitor/summary.json`
- Create: `spec/fixtures/monitor/devices.json`
- Create: `spec/fixtures/monitor/pools.json`
- Create: `spec/fixtures/monitor/stats.json`
- Create: `spec/fixtures/monitor/graph_data_hashrate.json`
- Create: `spec/fixtures/monitor/healthz.json`
- Create: `Rakefile` rake task `spec:refresh_monitor_fixtures`

These fixtures should be captured from a real running `cgminer_monitor`, not hand-rolled — hand-rolled fixtures drift from reality. The JSON below is the seed content an implementer commits on day one; after the first real monitor is available, run `rake spec:refresh_monitor_fixtures` to overwrite with real responses. The JSON shapes here match `cgminer_monitor/lib/cgminer_monitor/http_app.rb:69+` so the seeds behave correctly even before refresh.

- [ ] **Step 1: Write `miners.json`**

```json
{
  "miners": [
    {
      "id": "127.0.0.1:4028",
      "host": "127.0.0.1",
      "port": 4028,
      "available": true,
      "last_poll": "2026-04-16T10:30:00Z"
    }
  ]
}
```

- [ ] **Step 2: Write `summary.json`**

```json
{
  "miner": "127.0.0.1:4028",
  "command": "summary",
  "ok": true,
  "fetched_at": "2026-04-16T10:30:00Z",
  "response": {
    "STATUS": [{"STATUS": "S", "When": 1713262200}],
    "SUMMARY": [{"MHS 5s": 5123.45, "Accepted": 100, "Rejected": 1}]
  },
  "error": null
}
```

- [ ] **Step 3: Write `devices.json`**

```json
{
  "miner": "127.0.0.1:4028",
  "command": "devs",
  "ok": true,
  "fetched_at": "2026-04-16T10:30:00Z",
  "response": {
    "DEVS": [{"GPU": 0, "MHS 5s": 2561.7, "Temperature": 62.0, "Status": "Alive"}]
  },
  "error": null
}
```

- [ ] **Step 4: Write `pools.json`**

```json
{
  "miner": "127.0.0.1:4028",
  "command": "pools",
  "ok": true,
  "fetched_at": "2026-04-16T10:30:00Z",
  "response": {
    "POOLS": [
      {"POOL": 0, "URL": "stratum+tcp://pool.example.com:3333", "Status": "Alive", "Priority": 0},
      {"POOL": 1, "URL": "stratum+tcp://backup.example.com:3333", "Status": "Alive", "Priority": 1}
    ]
  },
  "error": null
}
```

- [ ] **Step 5: Write `stats.json`**

```json
{
  "miner": "127.0.0.1:4028",
  "command": "stats",
  "ok": true,
  "fetched_at": "2026-04-16T10:30:00Z",
  "response": {"STATS": [{"Elapsed": 3600}]},
  "error": null
}
```

- [ ] **Step 6: Write `graph_data_hashrate.json`** — 7-field shape matching `cgminer_monitor/lib/cgminer_monitor/http_app.rb:121-122`

```json
{
  "metric": "hashrate",
  "miner": "127.0.0.1:4028",
  "fields": ["ts", "ghs_5s", "ghs_av", "device_hardware_pct", "device_rejected_pct", "pool_rejected_pct", "pool_stale_pct"],
  "data": [
    [1713262140, 5.12, 5.10, 0.0, 0.0, 0.99, 0.0],
    [1713262200, 5.14, 5.11, 0.0, 0.0, 0.99, 0.0]
  ]
}
```

- [ ] **Step 7: Write `healthz.json`**

```json
{
  "status": "ok",
  "checks": {"mongo": "ok", "poller": "ok"}
}
```

- [ ] **Step 8: Add a `rake spec:refresh_monitor_fixtures` task**

Append to `Rakefile`:

```ruby
namespace :spec do
  desc 'Capture /v2/* responses from $CGMINER_MONITOR_URL into spec/fixtures/monitor/'
  task :refresh_monitor_fixtures do
    require 'http'
    require 'fileutils'

    base = ENV.fetch('CGMINER_MONITOR_URL') { abort 'Set CGMINER_MONITOR_URL' }
    miner = ENV.fetch('CGMINER_FIXTURE_MINER_ID') { '127.0.0.1:4028' }
    dir = File.expand_path('spec/fixtures/monitor', __dir__)
    FileUtils.mkdir_p(dir)

    fetch = lambda do |path, filename|
      resp = HTTP.timeout(5).get("#{base}#{path}")
      File.write(File.join(dir, filename), resp.body.to_s)
      puts "  wrote #{filename} (#{resp.status})"
    end

    fetch.call('/v2/miners', 'miners.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/summary", 'summary.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/devices", 'devices.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/pools",   'pools.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/stats",   'stats.json')
    fetch.call("/v2/graph_data/hashrate?miner=#{CGI.escape(miner)}",
               'graph_data_hashrate.json')
    fetch.call('/v2/healthz', 'healthz.json')
  end
end
```

- [ ] **Step 9: Commit**

```bash
git add spec/fixtures/monitor/ Rakefile
git commit -m "test: seed monitor response fixtures + refresh rake task"
```

### Task 2.2: `monitor_stubs.rb` — WebMock helpers

**Files:**
- Create: `spec/support/monitor_stubs.rb`

- [ ] **Step 1: Write `spec/support/monitor_stubs.rb`**

```ruby
# frozen_string_literal: true

require 'webmock/rspec'
require 'json'

module MonitorStubs
  FIXTURES_DIR = File.expand_path('../fixtures/monitor', __dir__)
  DEFAULT_URL  = 'http://localhost:9292'

  def stub_monitor_miners(fixture: 'miners.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners").to_return(status: status, body: body,
                                                     headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_summary(miner_id:, fixture: 'summary.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/summary")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_devices(miner_id:, fixture: 'devices.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/devices")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_pools(miner_id:, fixture: 'pools.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/pools")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_stats(miner_id:, fixture: 'stats.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/stats")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_graph(metric:, miner_id:, fixture:, url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/graph_data/#{metric}")
      .with(query: hash_including('miner' => miner_id))
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_healthz(url: DEFAULT_URL, status: 200, fixture: 'healthz.json')
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/healthz")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end
end

RSpec.configure do |config|
  config.include MonitorStubs
  config.before(:each) { WebMock.reset! }
end
```

- [ ] **Step 2: Commit**

```bash
git add spec/support/monitor_stubs.rb
git commit -m "test: WebMock helpers for monitor /v2/* endpoints"
```

### Task 2.3: `monitor_client.rb` — happy path

**Files:**
- Create: `spec/cgminer_manager/monitor_client_spec.rb`
- Create: `lib/cgminer_manager/monitor_client.rb`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write failing test for happy-path endpoints**

`spec/cgminer_manager/monitor_client_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe CgminerManager::MonitorClient do
  let(:url)    { 'http://localhost:9292' }
  let(:client) { described_class.new(base_url: url, timeout_ms: 2000) }
  let(:miner)  { '127.0.0.1:4028' }

  describe '#miners' do
    it 'returns the parsed miners array' do
      stub_monitor_miners
      result = client.miners
      expect(result[:miners]).to be_an(Array)
      expect(result[:miners].first[:id]).to eq('127.0.0.1:4028')
    end
  end

  describe '#summary' do
    it 'returns the snapshot hash for the miner' do
      stub_monitor_summary(miner_id: miner)
      result = client.summary(miner)
      expect(result[:ok]).to be true
      expect(result[:response][:SUMMARY].first[:'MHS 5s']).to eq(5123.45)
    end
  end

  describe '#devices' do
    it 'returns the devices snapshot' do
      stub_monitor_devices(miner_id: miner)
      expect(client.devices(miner)[:response][:DEVS]).to be_an(Array)
    end
  end

  describe '#pools' do
    it 'returns the pools snapshot' do
      stub_monitor_pools(miner_id: miner)
      expect(client.pools(miner)[:response][:POOLS].size).to eq(2)
    end
  end

  describe '#stats' do
    it 'returns the stats snapshot' do
      stub_monitor_stats(miner_id: miner)
      expect(client.stats(miner)[:response][:STATS]).to be_an(Array)
    end
  end

  describe '#graph_data' do
    it 'returns the {fields, data} envelope' do
      stub_monitor_graph(metric: 'hashrate', miner_id: miner, fixture: 'graph_data_hashrate.json')
      result = client.graph_data(metric: 'hashrate', miner_id: miner)
      expect(result[:fields]).to include('timestamp')
      expect(result[:data].first.size).to eq(3)
    end
  end

  describe '#healthz' do
    it 'returns the health payload' do
      stub_monitor_healthz
      expect(client.healthz[:status]).to eq('ok')
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

```bash
bundle exec rspec spec/cgminer_manager/monitor_client_spec.rb
```

Expected: NameError on `CgminerManager::MonitorClient`.

- [ ] **Step 3: Write `lib/cgminer_manager/monitor_client.rb`**

```ruby
# frozen_string_literal: true

require 'http'
require 'json'
require 'cgi'

module CgminerManager
  class MonitorClient
    def initialize(base_url:, timeout_ms: 2000)
      @base_url   = base_url.sub(%r{/\z}, '')
      @timeout_s  = timeout_ms / 1000.0
    end

    def miners
      get('/v2/miners')
    end

    def summary(miner_id)  = get("/v2/miners/#{CGI.escape(miner_id)}/summary")
    def devices(miner_id)  = get("/v2/miners/#{CGI.escape(miner_id)}/devices")
    def pools(miner_id)    = get("/v2/miners/#{CGI.escape(miner_id)}/pools")
    def stats(miner_id)    = get("/v2/miners/#{CGI.escape(miner_id)}/stats")

    def graph_data(metric:, miner_id:, since: nil)
      params = { miner: miner_id }
      params[:since] = since if since
      get("/v2/graph_data/#{metric}", params: params)
    end

    def healthz
      get('/v2/healthz')
    end

    private

    def get(path, params: {})
      url       = "#{@base_url}#{path}"
      started   = Time.now
      response  = HTTP.timeout(@timeout_s).get(url, params: params)
      duration_ms = ((Time.now - started) * 1000).round

      Logger.info(event: 'monitor.call', url: path, status: response.status.to_i,
                  duration_ms: duration_ms)

      unless response.status.success?
        raise MonitorError::ApiError.new("monitor returned #{response.status}",
                                         status: response.status.to_i,
                                         body: response.body.to_s)
      end

      JSON.parse(response.body.to_s, symbolize_names: true)
    rescue HTTP::ConnectionError, HTTP::TimeoutError, Errno::ECONNREFUSED => e
      Logger.warn(event: 'monitor.call.failed', url: path, error: e.class.to_s, message: e.message)
      raise MonitorError::ConnectionError, "monitor unreachable: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Require from top-level module**

Append to `lib/cgminer_manager.rb`:

```ruby
require_relative 'cgminer_manager/monitor_client'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/monitor_client_spec.rb
```

Expected: 7 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/monitor_client.rb lib/cgminer_manager.rb spec/cgminer_manager/monitor_client_spec.rb
git commit -m "feat(monitor_client): HTTP client for /v2/* endpoints"
```

### Task 2.4: `MonitorClient` error paths

**Files:**
- Modify: `spec/cgminer_manager/monitor_client_spec.rb`

- [ ] **Step 1: Add failure-path tests**

Append to `spec/cgminer_manager/monitor_client_spec.rb`:

```ruby
RSpec.describe CgminerManager::MonitorClient do
  let(:url)    { 'http://localhost:9292' }
  let(:client) { described_class.new(base_url: url, timeout_ms: 2000) }

  describe 'error handling' do
    it 'raises MonitorError::ApiError on 5xx' do
      stub_monitor_miners(status: 503)
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ApiError)
    end

    it 'attaches status and body on ApiError' do
      stub_monitor_miners(status: 500)
      client.miners
    rescue CgminerManager::MonitorError::ApiError => e
      expect(e.status).to eq(500)
      expect(e.body).not_to be_nil
    end

    it 'raises MonitorError::ConnectionError on connection refused' do
      stub_request(:get, "#{url}/v2/miners").to_raise(Errno::ECONNREFUSED)
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ConnectionError)
    end

    it 'raises MonitorError::ConnectionError on timeout' do
      stub_request(:get, "#{url}/v2/miners").to_timeout
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ConnectionError)
    end
  end

  describe 'observability' do
    it 'emits a monitor.call log line per request' do
      stub_monitor_miners
      logged = capture_logger_output { client.miners }
      expect(logged).to include('monitor.call')
    end
  end

  def capture_logger_output
    io = StringIO.new
    original = CgminerManager::Logger.output
    CgminerManager::Logger.output = io
    yield
    io.string
  ensure
    CgminerManager::Logger.output = original
  end
end
```

- [ ] **Step 2: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/monitor_client_spec.rb
```

Expected: 12 examples total, 0 failures.

- [ ] **Step 3: Commit**

```bash
git commit -am "test(monitor_client): error paths + timing log assertion"
```

---

## Phase 3 — Command plane: `PoolManager`

### Task 3.1: Port `FakeCgminer` + `cgminer_fixtures.rb`

**Files:**
- Create: `spec/support/fake_cgminer.rb` (verbatim copy from `cgminer_api_client`)
- Create: `spec/support/cgminer_fixtures.rb` (verbatim copy from `cgminer_api_client`)

- [ ] **Step 1: Copy FakeCgminer**

```bash
cp ../cgminer_api_client/spec/support/fake_cgminer.rb spec/support/fake_cgminer.rb
cp ../cgminer_api_client/spec/support/cgminer_fixtures.rb spec/support/cgminer_fixtures.rb
```

- [ ] **Step 2: Smoke-test require from spec_helper**

```bash
bundle exec ruby -Ilib -Ispec -rspec_helper -e 'puts FakeCgminer'
```

Expected: prints the class constant.

- [ ] **Step 3: Commit**

```bash
git add spec/support/fake_cgminer.rb spec/support/cgminer_fixtures.rb
git commit -m "test: port FakeCgminer + cgminer_fixtures from cgminer_api_client"
```

### Task 3.2: `PoolActionResult` — value object

**Files:**
- Create: `lib/cgminer_manager/pool_manager.rb` (initial — just the result types)
- Create: `spec/cgminer_manager/pool_manager_spec.rb`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write failing test for result types**

`spec/cgminer_manager/pool_manager_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe CgminerManager::PoolManager::PoolActionResult do
  let(:entry_ok) do
    CgminerManager::PoolManager::MinerEntry.new(
      miner: '10.0.0.1:4028', command_status: :ok, command_reason: nil,
      save_status: :ok, save_reason: nil
    )
  end

  let(:entry_failed) do
    CgminerManager::PoolManager::MinerEntry.new(
      miner: '10.0.0.2:4028', command_status: :failed,
      command_reason: RuntimeError.new('boom'),
      save_status: :skipped, save_reason: nil
    )
  end

  describe '#all_ok?' do
    it 'is true when every entry is ok' do
      result = described_class.new(entries: [entry_ok])
      expect(result.all_ok?).to be true
    end

    it 'is false when any entry is not ok' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.all_ok?).to be false
    end
  end

  describe '#any_failed?' do
    it 'is true when any entry failed' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.any_failed?).to be true
    end
  end

  describe '#successful' do
    it 'filters to entries with :ok command_status' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.successful.map(&:miner)).to eq(['10.0.0.1:4028'])
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

Expected: NameError on `CgminerManager::PoolManager::PoolActionResult`.

- [ ] **Step 3: Write the initial `lib/cgminer_manager/pool_manager.rb`**

```ruby
# frozen_string_literal: true

module CgminerManager
  class PoolManager
    MinerEntry = Data.define(:miner, :command_status, :command_reason,
                             :save_status, :save_reason) do
      def ok?     = command_status == :ok && save_status == :ok
      def failed? = command_status == :failed
    end

    PoolActionResult = Data.define(:entries) do
      def all_ok?     = entries.all?(&:ok?)
      def any_failed? = entries.any?(&:failed?)
      def successful  = entries.select(&:ok?)
      def failed      = entries.select(&:failed?)
      def indeterminate = entries.select { |e| e.command_status == :indeterminate }
    end
  end
end
```

- [ ] **Step 4: Require from top-level**

Append to `lib/cgminer_manager.rb`:

```ruby
require_relative 'cgminer_manager/pool_manager'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/pool_manager_spec.rb
```

Expected: 4 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/pool_manager.rb lib/cgminer_manager.rb spec/cgminer_manager/pool_manager_spec.rb
git commit -m "feat(pool_manager): PoolActionResult and MinerEntry value types"
```

### Task 3.3: `PoolManager#disable_pool` — happy path with verification

**Files:**
- Modify: `lib/cgminer_manager/pool_manager.rb`
- Modify: `spec/cgminer_manager/pool_manager_spec.rb`

- [ ] **Step 1: Add failing test for `disable_pool` happy path**

Append to `spec/cgminer_manager/pool_manager_spec.rb`:

```ruby
RSpec.describe CgminerManager::PoolManager do
  let(:miner_id) { '10.0.0.1:4028' }
  let(:miner) do
    instance_double(CgminerApiClient::Miner, host: '10.0.0.1', port: 4028)
  end

  before do
    allow(miner).to receive(:to_s).and_return(miner_id)
  end

  describe '#disable_pool' do
    context 'when the command succeeds and pool flips to Disabled' do
      it 'returns PoolActionResult with command_status :ok and save_status :ok' do
        expect(miner).to receive(:disablepool).with(1)
        expect(miner).to receive(:query).with(:pools).and_return(
          [{ 'POOL' => 1, 'STATUS' => 'Disabled' }]
        )
        expect(miner).to receive(:query).with(:save)

        pm = described_class.new([miner])
        result = pm.disable_pool(pool_index: 1)

        entry = result.entries.first
        expect(entry.command_status).to eq(:ok)
        expect(entry.save_status).to eq(:ok)
      end
    end
  end
end
```

- [ ] **Step 2: Run, confirm it fails**

Expected: NoMethodError on `described_class.new` / `#disable_pool`.

- [ ] **Step 3: Add the implementation**

Replace `lib/cgminer_manager/pool_manager.rb` with:

```ruby
# frozen_string_literal: true

module CgminerManager
  class PoolManager
    MinerEntry = Data.define(:miner, :command_status, :command_reason,
                             :save_status, :save_reason) do
      def ok?     = command_status == :ok && save_status == :ok
      def failed? = command_status == :failed
    end

    PoolActionResult = Data.define(:entries) do
      def all_ok?       = entries.all?(&:ok?)
      def any_failed?   = entries.any?(&:failed?)
      def successful    = entries.select(&:ok?)
      def failed        = entries.select(&:failed?)
      def indeterminate = entries.select { |e| e.command_status == :indeterminate }
    end

    def initialize(miners, thread_cap: 8)
      @miners     = miners
      @thread_cap = thread_cap
    end

    def disable_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.disablepool(pool_index)
          verify_pool_state(miner, pool_index, 'Disabled')
        end
      end
    end

    def enable_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.enablepool(pool_index)
          verify_pool_state(miner, pool_index, 'Alive')
        end
      end
    end

    def remove_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.removepool(pool_index)
          verify_pool_absent(miner, pool_index)
        end
      end
    end

    def add_pool(url:, user:, pass:)
      run_each do |miner|
        run_unverified(miner) do
          miner.addpool(url, user, pass)
        end
      end
    end

    def save
      run_each do |miner|
        run_unverified(miner) do
          miner.query(:save)
        end
      end
    end

    private

    def run_each(&block)
      queue = Queue.new
      @miners.each { |m| queue << m }

      results = Array.new(@miners.size)
      index_of = @miners.each_with_index.to_h
      mutex = Mutex.new

      worker_count = [@thread_cap, @miners.size].min
      worker_count = 1 if worker_count < 1

      workers = worker_count.times.map do
        Thread.new do
          loop do
            miner =
              begin
                queue.pop(true)
              rescue ThreadError
                break
              end
            entry = block.call(miner)
            mutex.synchronize { results[index_of[miner]] = entry }
          end
        end
      end
      workers.each(&:join)

      PoolActionResult.new(entries: results)
    end

    def run_verified(miner)
      command_status, command_reason = safe_call { yield }
      save_status, save_reason =
        if command_status == :failed
          [:skipped, nil]
        else
          safe_call { miner.query(:save) }
        end

      MinerEntry.new(miner: miner.to_s,
                     command_status: command_status, command_reason: command_reason,
                     save_status: save_status, save_reason: save_reason)
    end

    def run_unverified(miner)
      command_status, command_reason = safe_call { yield }
      save_status, save_reason = [:skipped, nil]
      MinerEntry.new(miner: miner.to_s,
                     command_status: command_status, command_reason: command_reason,
                     save_status: save_status, save_reason: save_reason)
    end

    def safe_call
      yield
      [:ok, nil]
    rescue PoolManagerError::DidNotConverge => e
      [:indeterminate, e]
    rescue CgminerApiClient::ConnectionError,
           CgminerApiClient::TimeoutError => e
      [:failed, e]
    rescue CgminerApiClient::ApiError => e
      [:failed, e]
    end

    def verify_pool_state(miner, pool_index, expected)
      pool = find_pool(miner, pool_index)
      return if pool && pool['STATUS'] == expected

      raise PoolManagerError::DidNotConverge,
            "pool #{pool_index} did not reach #{expected}; observed #{pool.inspect}"
    rescue CgminerApiClient::ConnectionError, CgminerApiClient::TimeoutError
      raise PoolManagerError::DidNotConverge, "verification query timed out for pool #{pool_index}"
    end

    def verify_pool_absent(miner, pool_index)
      pool = find_pool(miner, pool_index)
      return unless pool

      raise PoolManagerError::DidNotConverge, "pool #{pool_index} still present after remove"
    rescue CgminerApiClient::ConnectionError, CgminerApiClient::TimeoutError
      raise PoolManagerError::DidNotConverge, "verification query timed out for pool #{pool_index}"
    end

    def find_pool(miner, pool_index)
      miner.query(:pools).detect { |p| p['POOL'].to_s == pool_index.to_s }
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/pool_manager_spec.rb
```

Expected: 5 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(pool_manager): disable/enable/remove/add/save with 3-state result"
```

### Task 3.4: `PoolManager` — :indeterminate and :failed paths

**Files:**
- Modify: `spec/cgminer_manager/pool_manager_spec.rb`

- [ ] **Step 1: Add tests for verification timeout and errors**

Append to the `PoolManager` describe block:

```ruby
  describe '#disable_pool (verification did not converge)' do
    it 'marks command_status :indeterminate and still attempts save' do
      expect(miner).to receive(:disablepool).with(1)
      expect(miner).to receive(:query).with(:pools).and_return(
        [{ 'POOL' => 1, 'STATUS' => 'Alive' }]
      )
      expect(miner).to receive(:query).with(:save)

      pm = described_class.new([miner])
      result = pm.disable_pool(pool_index: 1)

      entry = result.entries.first
      expect(entry.command_status).to eq(:indeterminate)
      expect(entry.save_status).to eq(:ok)
    end
  end

  describe '#disable_pool (ApiError)' do
    it 'marks command_status :failed and skips save' do
      allow(miner).to receive(:disablepool)
        .and_raise(CgminerApiClient::ApiError, 'rejected')

      pm = described_class.new([miner])
      result = pm.disable_pool(pool_index: 1)

      entry = result.entries.first
      expect(entry.command_status).to eq(:failed)
      expect(entry.save_status).to eq(:skipped)
    end
  end

  describe '#disable_pool (ConnectionError)' do
    it 'marks command_status :failed and skips save' do
      allow(miner).to receive(:disablepool)
        .and_raise(CgminerApiClient::ConnectionError, 'refused')

      pm = described_class.new([miner])
      result = pm.disable_pool(pool_index: 1)

      entry = result.entries.first
      expect(entry.command_status).to eq(:failed)
      expect(entry.save_status).to eq(:skipped)
    end
  end

  describe '#add_pool (no verification)' do
    it 'returns :ok when addpool succeeds without any :pools re-query' do
      expect(miner).to receive(:addpool).with('stratum+tcp://p.example.com', 'u', 'p')
      expect(miner).not_to receive(:query).with(:pools)

      pm = described_class.new([miner])
      result = pm.add_pool(url: 'stratum+tcp://p.example.com', user: 'u', pass: 'p')

      expect(result.entries.first.command_status).to eq(:ok)
      expect(result.entries.first.save_status).to eq(:skipped)
    end

    it 'returns :failed when addpool raises ApiError' do
      allow(miner).to receive(:addpool).and_raise(CgminerApiClient::ApiError, 'bad url')

      pm = described_class.new([miner])
      result = pm.add_pool(url: 'x', user: 'u', pass: 'p')

      expect(result.entries.first.command_status).to eq(:failed)
    end
  end

  describe 'partial success across miners' do
    it 'records each miner independently' do
      good = instance_double(CgminerApiClient::Miner, host: '1', port: 2)
      bad  = instance_double(CgminerApiClient::Miner, host: '3', port: 4)
      allow(good).to receive(:to_s).and_return('1:2')
      allow(bad).to receive(:to_s).and_return('3:4')

      allow(good).to receive(:disablepool).with(1)
      allow(good).to receive(:query).with(:pools).and_return([{ 'POOL' => 1, 'STATUS' => 'Disabled' }])
      allow(good).to receive(:query).with(:save)

      allow(bad).to receive(:disablepool).with(1).and_raise(CgminerApiClient::ConnectionError)

      result = described_class.new([good, bad]).disable_pool(pool_index: 1)
      expect(result.successful.map(&:miner)).to eq(['1:2'])
      expect(result.failed.map(&:miner)).to eq(['3:4'])
    end
  end
```

- [ ] **Step 2: Run, confirm all pass**

```bash
bundle exec rspec spec/cgminer_manager/pool_manager_spec.rb
```

Expected: 10 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git commit -am "test(pool_manager): indeterminate, failed, add_pool no-verify, partial success"
```

---

## Phase 4 — HTTP app + views + assets

### Task 4.0: Preflight — verify Phase -1 monitor PR is deployed

**Files:** (none)

- [ ] **Step 1: Against a running monitor that's been upgraded to `MIN_MONITOR_VERSION`, curl each graph endpoint**

```bash
for m in hashrate temperature availability hardware_error pool_stale pool_rejected device_rejected; do
  echo "=== $m ==="
  curl -sS -o /dev/null -w "%{http_code}\n" "$CGMINER_MONITOR_URL/v2/graph_data/$m?miner=127.0.0.1%3A4028"
done
```

Expected: `200` for every metric. If any return `404`, Phase -1 is not merged/deployed — halt this plan and land the missing monitor endpoints first. The manager port depends on them.

- [ ] **Step 2: Record the MIN_MONITOR_VERSION this plan is built against**

Note the monitor tag you verified (e.g. `cgminer_monitor v0.3.0`) — this gets written into `README.md` (Task 6.2) and `MIGRATION.md` (Task 6.3) in place of the literal string `MIN_MONITOR_VERSION`.

No commit for this preflight.

### Task 4.1: `HttpApp` skeleton + `/healthz`

**Files:**
- Create: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/healthz_spec.rb`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write failing test for `/healthz`**

`spec/integration/healthz_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /healthz', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292',
      miners_file: write_miners_file
    )
  end

  def write_miners_file
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  context 'when monitor is healthy' do
    it 'returns 200 {ok: true}' do
      stub_monitor_healthz(status: 200)
      get '/healthz'
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body, symbolize_names: true)
      expect(body[:ok]).to be true
    end
  end

  context 'when monitor is unreachable' do
    it 'returns 503 {ok: false, reasons: [...]}' do
      stub_request(:get, 'http://localhost:9292/v2/healthz').to_raise(Errno::ECONNREFUSED)
      get '/healthz'
      expect(last_response.status).to eq(503)
      body = JSON.parse(last_response.body, symbolize_names: true)
      expect(body[:ok]).to be false
      expect(body[:reasons]).to include(match(/monitor/))
    end
  end

  context 'when miners.yml is unparseable' do
    it 'returns 503' do
      path = File.join(Dir.mktmpdir, 'miners.yml')
      File.write(path, 'not: valid: yaml: colons')
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: path
      )
      stub_monitor_healthz
      get '/healthz'
      expect(last_response.status).to eq(503)
    end
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: NameError on `CgminerManager::HttpApp`.

- [ ] **Step 3: Write minimum `lib/cgminer_manager/http_app.rb`**

```ruby
# frozen_string_literal: true

require 'sinatra/base'
require 'rack/protection'
require 'json'
require 'yaml'

module CgminerManager
  class HttpApp < Sinatra::Base
    class << self
      attr_accessor :monitor_url, :miners_file, :stale_threshold_seconds, :pool_thread_cap

      def configure_for_test!(monitor_url:, miners_file:,
                              stale_threshold_seconds: 300,
                              pool_thread_cap: 8)
        self.monitor_url             = monitor_url
        self.miners_file             = miners_file
        self.stale_threshold_seconds = stale_threshold_seconds
        self.pool_thread_cap         = pool_thread_cap
        reset_configured_miners! if respond_to?(:reset_configured_miners!)
      end
    end

    set :show_exceptions, false
    set :dump_errors, false
    set :host_authorization, { permitted_hosts: [] }

    get '/healthz' do
      reasons = []

      begin
        YAML.safe_load_file(self.class.miners_file)
      rescue StandardError => e
        reasons << "miners.yml unparseable: #{e.message}"
      end

      begin
        monitor_client.healthz
      rescue MonitorError => e
        reasons << "monitor unhealthy: #{e.message}"
      end

      content_type :json
      if reasons.empty?
        status 200
        JSON.generate(ok: true)
      else
        status 503
        JSON.generate(ok: false, reasons: reasons)
      end
    end

    private

    def monitor_client
      @monitor_client ||= MonitorClient.new(base_url: self.class.monitor_url)
    end
  end
end
```

- [ ] **Step 4: Require from top-level**

Append to `lib/cgminer_manager.rb`:

```ruby
require_relative 'cgminer_manager/http_app'
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rspec spec/integration/healthz_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/cgminer_manager/http_app.rb lib/cgminer_manager.rb spec/integration/healthz_spec.rb
git commit -m "feat(http): Sinatra app with /healthz"
```

### Task 4.2: `/api/v1/ping.json` endpoint

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/ping_spec.rb`

- [ ] **Step 1: Write failing test**

`spec/integration/ping_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /api/v1/ping.json', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  it 'returns the legacy shape {timestamp, available_miners, unavailable_miners}' do
    fake = instance_double(CgminerApiClient::Miner, available?: true)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    body = JSON.parse(last_response.body, symbolize_names: true)

    expect(last_response.status).to eq(200)
    expect(body.keys).to contain_exactly(:timestamp, :available_miners, :unavailable_miners)
    expect(body[:available_miners]).to eq(1)
    expect(body[:unavailable_miners]).to eq(0)
    expect(body[:timestamp]).to be_a(Integer)
  end

  it 'counts unavailable miners when Miner#available? returns false' do
    fake = instance_double(CgminerApiClient::Miner, available?: false)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    body = JSON.parse(last_response.body, symbolize_names: true)
    expect(body[:available_miners]).to eq(0)
    expect(body[:unavailable_miners]).to eq(1)
  end

  it 'does not depend on monitor being up' do
    stub_request(:get, /localhost:9292/).to_raise(Errno::ECONNREFUSED)
    fake = instance_double(CgminerApiClient::Miner, available?: true)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    expect(last_response.status).to eq(200)
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: 404 on unknown route.

- [ ] **Step 3: Add the route and direct `Miner#available?` iteration**

Add inside `HttpApp`:

```ruby
get '/api/v1/ping.json' do
  content_type :json

  available, unavailable = 0, 0
  configured_miners.each do |host, port|
    miner = CgminerApiClient::Miner.new(host, port)
    if miner.available?
      available += 1
    else
      unavailable += 1
    end
  end

  JSON.generate(
    timestamp:          Time.now.to_i,
    available_miners:   available,
    unavailable_miners: unavailable
  )
end
```

and in the private section, a shared memoized miners reader:

```ruby
def configured_miners
  self.class.configured_miners
end
```

Add to `class << self`:

```ruby
def configured_miners
  @configured_miners ||= begin
    raw = YAML.safe_load_file(miners_file)
    raw = [] if raw.nil?
    unless raw.is_a?(Array) && raw.all? { |m| m.is_a?(Hash) && m['host'] }
      raise ConfigError, "#{miners_file} must be a YAML list of {host, port} entries"
    end
    raw.map { |m| [m['host'], m['port'] || 4028].freeze }.freeze
  end
end

def reset_configured_miners!
  @configured_miners = nil
end
```

Also update `configure_for_test!` to call `reset_configured_miners!` at the end so reloads pick up per-spec tmpdir YAML files.

Add at the top of `http_app.rb`:

```ruby
require 'cgminer_api_client'
```

**Rationale for not using `CgminerApiClient::MinerPool`:** `MinerPool.new` (no args) hardcodes `config/miners.yml` relative to CWD, which breaks test isolation with per-spec tmpdir miner files. Direct iteration over `configured_miners` is simpler, fully testable, and matches what the spec's § 6.4 describes ("Computed from cgminers directly via `cgminer_api_client`").

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/ping_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(http): /api/v1/ping.json preserves legacy shape (cgminer-direct)"
```

### Task 4.3: Port HAML views + helper shims + Rails-ism rewrites

**Files:**
- Create: `views/layouts/application.haml`, `_header.haml`, `_footer.haml` (ported + rewritten)
- Create: `views/manager/*.haml` (ported, minus `_admin.haml` — dropped)
- Create: `views/miner/*.haml` (ported, minus `_admin.haml` — dropped)
- Create: `views/shared/**/*.haml` (ported, minus `_run.haml` and the `run/` subtree — dropped)
- Modify: `lib/cgminer_manager/http_app.rb` (big helper block)

- [ ] **Step 1: Copy views, dropping the ones that support cut `/run` endpoints**

```bash
find app/views -type f -name '*.haml' | while read -r src; do
  rel="${src#app/views/}"
  # Drop anything under shared/run/, the _run partial, and the _admin partials
  # (all of which were UI wrappers for POST /manager/run or POST /miner/:id/run).
  case "$rel" in
    shared/_run.html.haml) continue ;;
    shared/run/*)          continue ;;
    manager/_admin.html.haml) continue ;;
    miner/_admin.html.haml)   continue ;;
  esac
  dst="views/${rel%.html.haml}.haml"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
done
```

- [ ] **Step 2: Write the full helper shim set + render_partial in `http_app.rb`**

The current views (per `grep -r` against `app/views`) depend on these Rails helpers: `link_to`, `image_tag`, `stylesheet_link_tag`, `javascript_include_tag`, `csrf_meta_tags` (plural), `content_for` / `content_for?` / `yield(:name)`, `hidden_field_tag`, `text_field_tag`, `label_tag`, `submit_tag`, `raw`, `root_url`, `miner_url`. Add all of them:

```ruby
helpers do
  def h(text)  = Rack::Utils.escape_html(text.to_s)
  def raw(str) = str.to_s.html_safe? ? str : str.to_s # Sinatra HAML honors `!=` for raw output; this shim lets views that use `raw "..."` keep compiling.

  def root_url                  = '/'
  def miner_url(miner_id)       = "/miner/#{CGI.escape(miner_id.to_s)}"
  def manager_manage_pools_path = '/manager/manage_pools'
  def miner_manage_pools_path(miner_id) = "#{miner_url(miner_id)}/manage_pools"

  def link_to(text, href, **opts)
    attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
    %(<a href="#{h(href)}" #{attrs}>#{text.is_a?(String) ? h(text) : text}</a>)
  end

  def image_tag(src, **opts)
    attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
    %(<img src="#{h(src)}" #{attrs}>)
  end

  def stylesheet_link_tag(name)
    %(<link rel="stylesheet" href="/css/#{h(name)}.css">)
  end

  def javascript_include_tag(name)
    %(<script src="/js/#{h(name)}.js"></script>)
  end

  def csrf_meta_tag
    %(<meta name="csrf-token" content="#{h(csrf_token)}">)
  end
  # Alias so the layout's existing `= csrf_meta_tags` call site compiles:
  def csrf_meta_tags = csrf_meta_tag

  def csrf_token
    Rack::Protection::AuthenticityToken.token(env['rack.session'] || {})
  end

  def hidden_field_tag(name, value = nil)
    %(<input type="hidden" name="#{h(name)}" value="#{h(value)}">)
  end

  def text_field_tag(name, value = nil, placeholder: nil)
    ph = placeholder ? %( placeholder="#{h(placeholder)}") : ''
    %(<input type="text" name="#{h(name)}" value="#{h(value)}"#{ph}>)
  end

  def label_tag(name, text)
    %(<label for="#{h(name)}">#{h(text)}</label>)
  end

  def submit_tag(text)
    %(<input type="submit" value="#{h(text)}">)
  end

  # Render a partial. Rails-style 'shared/foo' or 'shared/graphs/hashrate'
  # maps to views/shared/_foo.haml / views/shared/graphs/_hashrate.haml.
  def render_partial(name, locals: {})
    parts = name.split('/')
    parts[-1] = "_#{parts[-1]}"
    haml parts.join('/').to_sym, layout: false, locals: locals
  end
end
```

**Content helpers (`content_for` / `yield_content`) come from `sinatra-contrib`** — the DIY `capture_haml` approach doesn't work with Haml 6 (that method was removed). At the top of `http_app.rb`, add:

```ruby
require 'sinatra/content_for'
```

and inside the class body:

```ruby
helpers Sinatra::ContentFor
```

This gives you a working `content_for :name do ... end` and `yield_content :name`, both tested on Sinatra + Haml 6.

- [ ] **Step 3: Rewrite Rails-isms in the two ported views that embed them**

`views/layouts/_header.haml` — replace `Time.zone.now` with `Time.now`:

```
%span= Time.now.strftime("%H:%M:%S")
```

`views/manager/index.haml` — in the embedded JS block, replace `Rails.application.class.parent_name` with the literal string `"CgminerManager"` and change `'#{root_url}'` to `'/'`:

```haml
:javascript
  // ...
  $('#manager').load('/', function() {
    // ...
    $('title').text('CgminerManager');
  });
```

`views/miner/show.haml` — same pattern, plus replace `miner_url(@miner_id)` with the value computed by the controller (pass it as a view var `@miner_url`):

```haml
:javascript
  $('#miner-show').load('#{@miner_url}', function() {
    $('#updated').removeClass('updating').html("<b>Updated:</b> <span>" + new Date().toLocaleTimeString() + "</span>");
    $('title').text('CgminerManager');
  });
```

And the previous/next-miner links in `miner/show.haml` (currently `miner_url(@miner_id - 1)`, which assumed integer ids) — since miner ids are now `host:port` strings with no natural arithmetic, compute prev/next in the controller and pass as `@prev_miner_url` / `@next_miner_url`, each nil-safe. Update the `.left` / `.right` blocks:

```haml
- if @prev_miner_url
  .left= link_to raw("&laquo; Previous Miner"), @prev_miner_url
- if @next_miner_url
  .right= link_to raw("Next Miner &raquo;"), @next_miner_url
```

The controller (Task 4.7) computes these from `configured_miners` list — the miner before/after the current one, nil if at either end.

**Also rewrite `= yield :sym` to `= yield_content :sym`** — Rails's `yield :name` looks up a named content buffer. Sinatra+Haml's bare `yield` yields to the layout's implicit content block, not a named buffer; `sinatra-contrib`'s `yield_content :name` is the named-buffer equivalent.

```bash
# manager/index.haml and any other surviving view with `yield :<name>`
find views -name '*.haml' -exec sed -i '' -E 's/= yield :([A-Za-z_][A-Za-z0-9_]*)/= yield_content :\1/g' {} +
```

Verify with:

```bash
grep -n 'yield :' views/ -r
```

Expected: empty output (all `yield :sym` converted).

**Final Rails-ism sanity scan:**

```bash
grep -rn "Time\.zone\|Rails\.application\|root_url\|\.parent_name" views/ || true
```

Expected: empty. Any straggler hits should be rewritten to plain Ruby / literal strings before moving on.

- [ ] **Step 4: Update the layout's asset paths**

`views/layouts/application.haml` currently has `= stylesheet_link_tag "application"` and `= javascript_include_tag "application"`. With Sprockets gone, we serve static files directly. Replace with explicit tags for each file:

```haml
!!! 5
%html
  %head
    %title CgminerManager
    %meta{ charset: 'utf-8' }
    != csrf_meta_tag
    %link{ rel: 'stylesheet', href: '/css/application.css' }
    %link{ rel: 'stylesheet', href: '/css/base.css' }
    %link{ rel: 'stylesheet', href: '/css/manager.css' }
    %link{ rel: 'stylesheet', href: '/css/miner.css' }
    %link{ rel: 'stylesheet', href: '/css/mobile.css' }
    %script{ src: '/js/jquery-3.6.0.min.js' }
    %script{ src: '/js/jquery.cookie.js' }
    %script{ src: '/js/chart.min.js' }
    %script{ src: '/js/config.js' }
    %script{ src: '/js/graph.js' }
    %script{ src: '/js/audio.js' }
    %script{ src: '/js/manager.js' }
    %script{ src: '/js/miner.js' }
  %body
    = haml :'layouts/_header', layout: false
    = yield
    = haml :'layouts/_footer', layout: false
```

- [ ] **Step 5: Find-and-replace `render partial: …` in every ported view**

Sinatra HAML doesn't have Rails's `render partial:` helper. The current views use several shapes — all of them need to become `render_partial`:

- `render partial: 'shared/manage_pools', locals: { miner: m }` — namespaced, with locals
- `render partial: 'shared/graphs/hashrate'` — namespaced, no locals
- `render partial: 'admin'` — bare, relative to current view's directory (e.g. `manager/_admin.haml`)
- `render 'shared/foo'` — shorthand, no `partial:` keyword

Run each transformation in order:

```bash
# 1. Namespaced WITH locals:  render partial: 'X/Y', locals: {...}
find views -name '*.haml' -exec sed -i '' \
  -E "s/render partial: *'([^']+)', *locals: *(\{[^}]*\})/render_partial '\1', locals: \2/g" {} +

# 2. Namespaced WITHOUT locals:  render partial: 'X/Y'  (must NOT match the relative form)
find views -name '*.haml' -exec sed -i '' \
  -E "s/render partial: *'([^']+\/[^']+)'([^,]|$)/render_partial '\1'\2/g" {} +

# 3. Relative (no slash) WITHOUT locals:  render partial: 'admin'
find views -name '*.haml' -exec sed -i '' \
  -E "s/render partial: *'([^'\/]+)'([^,]|$)/render_partial '\1'\2/g" {} +

# 4. Shorthand no-keyword form:  render 'X/Y'
find views -name '*.haml' -exec sed -i '' \
  -E "s/render 'shared\/([^']+)'/render_partial 'shared\/\1'/g" {} +
```

Audit the result:

```bash
grep -n "render partial:" views/ -r || true
grep -n "render '" views/ -r         || true
```

Both expected empty. Any remaining hit needs a targeted manual edit.

- [ ] **Step 6: Drop references to cut `_admin` / `_run` partials**

The partials themselves were not copied (Step 1's exclusions), but surviving views may still reference them. Catch **all** shapes:

```bash
grep -En "render_partial *['\"](manager/)?admin['\"]"  views/ -r || true
grep -En "render_partial *['\"](miner/)?admin['\"]"    views/ -r || true
grep -En "render_partial *['\"](shared/)?run['\"]"     views/ -r || true
grep -En "render_partial *['\"]shared/run/"            views/ -r || true
```

For every hit, delete that line. Spec-mandated hits are:

- `views/manager/index.haml` around line 19 (was `render partial: 'admin'`) — delete.
- `views/miner/show.haml` around line 30 (was `render partial: 'admin'`) — delete.

Re-run the greps until empty. This is the last UI-surface change; anything still referencing the cut `/run` verbs must be pruned.

- [ ] **Step 7: Commit**

```bash
git add views/ lib/cgminer_manager/http_app.rb
git commit -m "feat(views): port HAML with shims; rewrite Rails-isms; drop /run UI"
```

### Task 4.4: Move JS + CSS to `public/` (preserving existing `public/` contents)

**Files:**
- Create: `public/js/*` (from `app/assets/javascripts/*`)
- Create: `public/css/*` (from `app/assets/stylesheets/*`)
- Keep as-is: `public/favicon.ico`, `public/forkme.png`, `public/robots.txt`, `public/audio/`, `public/screenshots/` — the existing tree is preserved; we only ADD `js/` and `css/` subdirectories.

- [ ] **Step 1: Move JS, renaming for Sinatra static serving**

```bash
mkdir -p public/js
cp app/assets/javascripts/Chart.min.js public/js/chart.min.js
cp app/assets/javascripts/manager.js public/js/manager.js
cp app/assets/javascripts/miner.js public/js/miner.js
cp app/assets/javascripts/graph.js public/js/graph.js
cp app/assets/javascripts/audio.js public/js/audio.js
cp app/assets/javascripts/config.js public/js/config.js
cp app/assets/javascripts/jquery.cookie.js public/js/jquery.cookie.js
# Add a checked-in jQuery 3.6:
curl -o public/js/jquery-3.6.0.min.js https://code.jquery.com/jquery-3.6.0.min.js
```

- [ ] **Step 2: Move CSS. SCSS files must be rendered to plain CSS since no bundler**

```bash
mkdir -p public/css
# If scss files have no actual SCSS syntax, rename to .css:
for f in app/assets/stylesheets/*.css.scss; do
  base=$(basename "$f" .css.scss)
  cp "$f" "public/css/${base}.css"
done
cp app/assets/stylesheets/application.css public/css/application.css
```

Verify by opening each `public/css/*.css` and eyeballing — if any SCSS features (variables, nesting) are in use, manually flatten them to plain CSS.

- [ ] **Step 3: Install CSRF ajax setup in `manager.js` and `miner.js`**

Add at the top of each:

```javascript
$(function() {
  var token = $('meta[name="csrf-token"]').attr('content');
  if (token) {
    $.ajaxSetup({
      beforeSend: function(xhr) { xhr.setRequestHeader('X-CSRF-Token', token); }
    });
  }
});
```

- [ ] **Step 4: Commit**

```bash
git add public/
git commit -m "feat(assets): move JS/CSS to public/, add CSRF ajax setup"
```

### Task 4.5: Enable sessions + CSRF in `HttpApp`

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`

- [ ] **Step 1: Add session + rack-protection config**

At the top of the class body in `http_app.rb`:

```ruby
configure do
  use Rack::Session::Cookie,
      key: 'cgminer_manager.session',
      secret: ENV.fetch('SESSION_SECRET') { SecureRandom.hex(32) },
      same_site: :lax
  use Rack::Protection::AuthenticityToken
end
```

Add `require 'securerandom'` at the top.

- [ ] **Step 2: Verify existing tests still pass**

```bash
bundle exec rspec spec/integration/
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(http): enable Sinatra sessions + rack-protection CSRF"
```

### Task 4.6: Dashboard route `GET /`

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/dashboard_spec.rb`

- [ ] **Step 1: Write failing integration test**

`spec/integration/dashboard_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  context 'when monitor is healthy' do
    before do
      stub_monitor_miners
      stub_monitor_summary(miner_id: '127.0.0.1:4028')
      stub_monitor_devices(miner_id: '127.0.0.1:4028')
      stub_monitor_pools(miner_id: '127.0.0.1:4028')
      stub_monitor_stats(miner_id: '127.0.0.1:4028')
    end

    it 'returns 200 and includes the miner row' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('127.0.0.1:4028')
    end
  end

  context 'when monitor is unreachable' do
    before do
      stub_request(:get, %r{localhost:9292/v2/.*}).to_raise(Errno::ECONNREFUSED)
    end

    it 'renders 200 with a "data source unavailable" banner (no 500)' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('data source unavailable')
    end
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: either 404 or missing constants.

- [ ] **Step 3: Implement the dashboard route**

Add inside `HttpApp`:

```ruby
get '/' do
  @view = build_dashboard_view_model
  haml :'manager/index'
end
```

And in helpers:

```ruby
def build_dashboard_view_model
  begin
    miners = monitor_client.miners[:miners]
  rescue MonitorError => e
    # Fall back to miners.yml (local whitelist) so the page still renders
    # with tile shells even when monitor is unreachable.
    fallback_miners = configured_miners.map { |host, port| { id: "#{host}:#{port}", host: host, port: port } }
    return { miners: fallback_miners, snapshots: {},
             banner: "data source unavailable (#{e.message})",
             stale_threshold: self.class.stale_threshold_seconds || 300 }
  end

  snapshots = fetch_snapshots_for(miners)
  { miners: miners, snapshots: snapshots, banner: nil,
    stale_threshold: self.class.stale_threshold_seconds || 300 }
end

def fetch_snapshots_for(miners)
  queue = Queue.new
  miners.each { |m| queue << m }
  results = {}
  mutex = Mutex.new

  worker_count = [self.class.pool_thread_cap || 8, miners.size].min
  worker_count = 1 if worker_count < 1
  threads = worker_count.times.map do
    Thread.new do
      loop do
        miner =
          begin
            queue.pop(true)
          rescue ThreadError
            break
          end

        tile = {
          summary: safe_fetch { monitor_client.summary(miner[:id]) },
          devices: safe_fetch { monitor_client.devices(miner[:id]) },
          pools:   safe_fetch { monitor_client.pools(miner[:id]) },
          stats:   safe_fetch { monitor_client.stats(miner[:id]) }
        }

        mutex.synchronize { results[miner[:id]] = tile }
      end
    end
  end
  threads.each(&:join)
  results
end

def safe_fetch
  yield
rescue MonitorError => e
  { error: e.message }
end
```

Add `attr_accessor :stale_threshold_seconds, :pool_thread_cap` to the `class << self` block.

The default `views/manager/index.haml` must be updated to iterate `@view[:miners]` using the new shape (host:port IDs, `@view[:snapshots][miner[:id]]`). Also add the banner:

```haml
- if @view[:banner]
  .alert.alert-warning= @view[:banner]
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/dashboard_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(http): dashboard route with parallel snapshot fetch + failure banner"
```

### Task 4.7: Per-miner page `GET /miner/:miner_id`

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/miner_page_spec.rb`

- [ ] **Step 1: Write failing test**

`spec/integration/miner_page_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /miner/:miner_id', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
    stub_monitor_miners
    stub_monitor_summary(miner_id: '127.0.0.1:4028')
    stub_monitor_devices(miner_id: '127.0.0.1:4028')
    stub_monitor_pools(miner_id: '127.0.0.1:4028')
    stub_monitor_stats(miner_id: '127.0.0.1:4028')
  end

  it 'renders the miner detail page (URL-encoded host:port)' do
    get "/miner/#{CGI.escape('127.0.0.1:4028')}"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('127.0.0.1:4028')
  end

  it 'returns 404 when miner is not in miners.yml' do
    get "/miner/#{CGI.escape('99.99.99.99:4028')}"
    expect(last_response.status).to eq(404)
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: 404 on both (route not defined).

- [ ] **Step 3: Add the route**

Inside `HttpApp`:

```ruby
get '/miner/:miner_id' do
  miner_id = CGI.unescape(params[:miner_id])
  halt 404 unless miner_configured?(miner_id)

  @miner_id = miner_id
  @miner_url = miner_url(miner_id)
  @prev_miner_url, @next_miner_url = neighbor_urls(miner_id)
  @view = build_miner_view_model(miner_id)
  haml :'miner/show'
end
```

Helpers:

```ruby
def miner_configured?(miner_id)
  configured_miners.any? { |host, port| "#{host}:#{port}" == miner_id }
end

def neighbor_urls(miner_id)
  ids = configured_miners.map { |host, port| "#{host}:#{port}" }
  idx = ids.index(miner_id)
  prev = idx && idx.positive?           ? miner_url(ids[idx - 1]) : nil
  nxt  = idx && idx < ids.size - 1      ? miner_url(ids[idx + 1]) : nil
  [prev, nxt]
end

def build_miner_view_model(miner_id)
  {
    miner_id: miner_id,
    snapshots: {
      summary: safe_fetch { monitor_client.summary(miner_id) },
      devices: safe_fetch { monitor_client.devices(miner_id) },
      pools:   safe_fetch { monitor_client.pools(miner_id) },
      stats:   safe_fetch { monitor_client.stats(miner_id) }
    }
  }
end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/miner_page_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(http): per-miner page with host:port URL scheme"
```

### Task 4.8: Graph data pass-through + reshape

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/graph_data_spec.rb`

- [ ] **Step 1: Write failing test**

`spec/integration/graph_data_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /miner/:miner_id/graph_data/:metric', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new
  let(:miner_id) { '127.0.0.1:4028' }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
    stub_monitor_graph(metric: 'hashrate', miner_id: miner_id,
                       fixture: 'graph_data_hashrate.json')
  end

  it 'projects {fields, data} to [[ts, ghs_5s, ghs_av], ...] for legacy Chart.js' do
    get "/miner/#{CGI.escape(miner_id)}/graph_data/hashrate"
    expect(last_response.status).to eq(200)

    body = JSON.parse(last_response.body)
    expect(body).to be_an(Array)
    expect(body.first).to be_an(Array)
    expect(body.first.size).to eq(3) # legacy graph.js expects exactly [ts, ghs_5s, ghs_av]
    expect(body.first[0]).to eq(1713262140)
    expect(body.first[1]).to eq(5.12)
    expect(body.first[2]).to eq(5.10)
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: 404 — route not defined.

- [ ] **Step 3: Implement the reshape route with per-metric column projection**

Monitor returns a 7-field hashrate envelope but legacy `graph.js` only reads `[ts, ghs_5s, ghs_av]`. Project each metric down to the columns the legacy JS actually uses. Inside `HttpApp`:

```ruby
GRAPH_METRIC_PROJECTIONS = {
  'hashrate'         => %w[ts ghs_5s ghs_av],
  'temperature'      => %w[ts min avg max],
  'availability'     => %w[ts available],
  'hardware_error'   => %w[ts device_hardware_pct],
  'device_rejected'  => %w[ts device_rejected_pct],
  'pool_rejected'    => %w[ts pool_rejected_pct],
  'pool_stale'       => %w[ts pool_stale_pct]
}.freeze

get '/miner/:miner_id/graph_data/:metric' do
  miner_id = CGI.unescape(params[:miner_id])
  halt 404 unless miner_configured?(miner_id)

  projection = GRAPH_METRIC_PROJECTIONS[params[:metric]]
  halt 404 unless projection

  envelope = monitor_client.graph_data(metric: params[:metric],
                                       miner_id: miner_id,
                                       since: params[:since])

  fields = envelope[:fields] || []
  rows   = envelope[:data]   || []
  indices = projection.map { |f| fields.index(f) }

  projected = rows.map { |row| indices.map { |i| i ? row[i] : nil } }

  content_type :json
  JSON.generate(projected)
end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/graph_data_spec.rb
```

Expected: 1 example, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(http): graph_data reshape for Chart.js"
```

### Task 4.9: Staleness surfacing

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Modify: `views/manager/_miner_pool.haml` (or equivalent tile partial)
- Create: `spec/integration/staleness_spec.rb`

- [ ] **Step 1: Write failing test**

`spec/integration/staleness_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'staleness surfacing on dashboard', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path,
      stale_threshold_seconds: 60
    )
    stub_monitor_miners
    stub_monitor_devices(miner_id: '127.0.0.1:4028')
    stub_monitor_pools(miner_id: '127.0.0.1:4028')
    stub_monitor_stats(miner_id: '127.0.0.1:4028')
  end

  it 'renders a stale badge when fetched_at is older than threshold' do
    old_ts = (Time.now.utc - 3600).iso8601
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: true,
      fetched_at: old_ts,
      response: { SUMMARY: [{ :'MHS 5s' => 100 }] }, error: nil
    }.to_json
    stub_request(:get, %r{/v2/miners/127.0.0.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.body).to match(/updated \d+m ago/i)
  end

  it 'renders a "waiting for first poll" placeholder when response is nil' do
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: nil,
      fetched_at: nil, response: nil, error: nil
    }.to_json
    stub_request(:get, %r{/v2/miners/127.0.0.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.body).to include('waiting for first poll')
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Expected: the strings are not in the output.

- [ ] **Step 3: Add helper + update view**

Inside `HttpApp` helpers:

```ruby
def staleness_badge(fetched_at, threshold)
  return 'waiting for first poll' if fetched_at.nil?

  age = Time.now.utc - Time.parse(fetched_at)
  return nil if age < threshold

  minutes = (age / 60).to_i
  "updated #{minutes}m ago"
end

def setter_for_stale
  self.class.stale_threshold_seconds || 300
end
```

Also add `attr_accessor :stale_threshold_seconds` to `class << self` if not already present, and accept it in `configure_for_test!`.

In `views/manager/_miner_pool.haml`, near where each tile renders a summary:

```haml
- badge = staleness_badge(snapshot[:summary] && snapshot[:summary][:fetched_at], @view[:stale_threshold])
- if badge
  .staleness-badge= badge
```

Use `"waiting for first poll"` as the literal text for the nil case (either by making `staleness_badge` return it directly or via another helper).

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/staleness_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(ui): staleness badge + waiting-for-first-poll placeholder"
```

### Task 4.10: Pool management routes `POST /manager/manage_pools` and `POST /miner/:miner_id/manage_pools`

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`
- Create: `spec/integration/pool_management_spec.rb`

- [ ] **Step 1: Write failing test using FakeCgminer**

`FakeCgminer` takes a `responses:` hash mapping the **bare command name** to a JSON string (see `cgminer_api_client/spec/support/fake_cgminer.rb:133-135`). Arguments are NOT part of the key — the server reads the `command` field out of the parsed request JSON and looks it up directly. If you need to assert that the request carried specific parameters, use the `on_request:` callback to capture the raw request bytes. Construct small JSON fixtures inline for clarity; `CgminerFixtures::POOLS` can seed a "one pool, Disabled status" base when it simplifies things.

`spec/integration/pool_management_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'pool management', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:fake_responses) do
    {
      'disablepool' => %({"STATUS":[{"STATUS":"S","When":1,"Code":47,"Msg":"Pool 1 disabled","Description":"cgminer 4.11.1"}],"id":1}),
      'pools'       => %({"STATUS":[{"STATUS":"S","When":1,"Code":7,"Msg":"1 Pool(s)","Description":"cgminer 4.11.1"}],"POOLS":[{"POOL":1,"URL":"x","Status":"Disabled"}],"id":1}),
      'save'        => %({"STATUS":[{"STATUS":"S","When":1,"Code":20,"Msg":"Configuration saved","Description":"cgminer 4.11.1"}],"id":1})
    }
  end

  let(:fake) { FakeCgminer.new(responses: fake_responses).start }
  after { fake.stop }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: #{fake.port}\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  describe 'POST /manager/manage_pools (disable_pool)' do
    it 'responds 200 with a per-miner status partial' do
      token = fetch_csrf_token

      post '/manager/manage_pools',
           { action_name: 'disable', pool_index: 1, authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/127\.0\.0\.1:#{fake.port}/)
    end
  end

  describe 'POST /manager/manage_pools (add_pool)' do
    let(:fake_responses) do
      {
        'addpool' => %({"STATUS":[{"STATUS":"S","When":1,"Code":55,"Msg":"Added pool 'x'","Description":"cgminer 4.11.1"}],"id":1})
      }
    end

    it 'returns 200 with an :ok entry and :skipped save (no verification step)' do
      token = fetch_csrf_token
      post '/manager/manage_pools',
           { action_name: 'add', url: 'stratum+tcp://x:3333', user: 'u', pass: 'p',
             authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/127\.0\.0\.1:#{fake.port}/)
      # :add_pool does not re-query :pools (verification skipped per spec § 7.3)
      # and does not trigger a :save. The assertion here is that the test
      # ran to completion (no hang, no 500) — the explicit 'save' key is
      # deliberately absent from fake_responses.
    end
  end

  describe 'CSRF enforcement' do
    it 'returns 403 on POST without a token' do
      post '/manager/manage_pools', action_name: 'disable', pool_index: 1
      expect(last_response.status).to eq(403)
    end
  end

  def fetch_csrf_token
    # The dashboard GET renders the layout and sets a session cookie that
    # matches the returned token. Rack::Test's cookie jar carries the
    # session forward to the subsequent POST.
    stub_monitor_miners
    stub_monitor_summary(miner_id: "127.0.0.1:#{fake.port}")
    stub_monitor_devices(miner_id: "127.0.0.1:#{fake.port}")
    stub_monitor_pools(miner_id: "127.0.0.1:#{fake.port}")
    stub_monitor_stats(miner_id: "127.0.0.1:#{fake.port}")

    get '/'
    last_response.body[/csrf-token" content="([^"]+)"/, 1]
  end
end
```

> **Implementation note:** `FakeCgminer`'s `responses:` hash is keyed by the **bare command name** (`'disablepool'`, `'pools'`, `'save'`) — arguments are read from a separate `parameter` field in the request JSON and are NOT part of the lookup key. See `cgminer_api_client/spec/support/fake_cgminer.rb:133-135`. If you need to assert specific parameters were sent, pass `on_request: ->(bytes) { recorded << bytes }` when constructing the server. A missing key falls through to `CgminerFixtures.invalid_command`, producing a STATUS=E response that `cgminer_api_client` surfaces as `ApiError`.

- [ ] **Step 2: Run, confirm failure**

Expected: 404 on route or instrumentation errors.

- [ ] **Step 3: Add the routes**

```ruby
post '/manager/manage_pools' do
  action_name = params[:action_name].to_s
  pool_index  = params[:pool_index].to_i

  pm = build_pool_manager_for_all
  result = dispatch_pool_action(pm, action_name, pool_index)

  @result = result
  haml :'shared/manage_pools', layout: false
end

post '/miner/:miner_id/manage_pools' do
  miner_id = CGI.unescape(params[:miner_id])
  halt 404 unless miner_configured?(miner_id)

  pm = build_pool_manager_for([miner_id])
  result = dispatch_pool_action(pm, params[:action_name], params[:pool_index].to_i)

  @result = result
  haml :'shared/manage_pools', layout: false
end
```

Helpers:

```ruby
def build_pool_manager_for_all
  miners = configured_miners.map do |host, port|
    CgminerApiClient::Miner.new(host, port)
  end
  PoolManager.new(miners, thread_cap: self.class.pool_thread_cap || 8)
end

def build_pool_manager_for(miner_ids)
  miners = miner_ids.map do |id|
    host, port = id.split(':', 2)
    CgminerApiClient::Miner.new(host, port.to_i)
  end
  PoolManager.new(miners)
end

def dispatch_pool_action(pm, action_name, pool_index)
  case action_name
  when 'disable' then pm.disable_pool(pool_index: pool_index)
  when 'enable'  then pm.enable_pool(pool_index: pool_index)
  when 'remove'  then pm.remove_pool(pool_index: pool_index)
  when 'add'     then pm.add_pool(url: params[:url], user: params[:user], pass: params[:pass])
  else halt 400, "unknown action: #{action_name}"
  end
end
```

Update `views/shared/_manage_pools.haml` to iterate `@result.entries` and render each with a ✓ / ✗ / ⚠ icon based on `command_status`.

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rspec spec/integration/pool_management_spec.rb
```

Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(http): pool management routes with 3-state results + CSRF"
```

### Task 4.11: 404 / 500 error pages

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`

- [ ] **Step 1: Add handlers**

```ruby
not_found do
  content_type :html
  haml :'errors/404'
end

error do
  Logger.error(event: 'http.500', error: env['sinatra.error'].class.to_s,
               message: env['sinatra.error'].message,
               backtrace: env['sinatra.error'].backtrace&.first(10))
  content_type :html
  haml :'errors/500'
end
```

- [ ] **Step 2: Add tiny templates**

`views/errors/404.haml`:

```haml
%h1 Not Found
%p The page you requested does not exist.
```

`views/errors/500.haml`:

```haml
%h1 Something went wrong
%p An unexpected error occurred.
```

- [ ] **Step 3: Commit**

```bash
git add views/errors/ lib/cgminer_manager/http_app.rb
git commit -m "feat(http): 404 and 500 handlers with structured error logging"
```

### Task 4.12: Per-render timing log

**Files:**
- Modify: `lib/cgminer_manager/http_app.rb`

- [ ] **Step 1: Add before/after hooks**

```ruby
before do
  @request_started_at = Time.now
  @monitor_calls = 0
end

after do
  Logger.info(event: 'http.request',
              path: request.path,
              method: request.request_method,
              status: response.status,
              render_ms: ((Time.now - @request_started_at) * 1000).round)
end
```

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(http): per-request structured timing log"
```

---

## Phase 5 — Server + CLI

### Task 5.1: `server.rb` — Puma launcher with graceful shutdown

**Files:**
- Create: `lib/cgminer_manager/server.rb`
- Create: `config/puma.rb`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write `config/puma.rb`**

```ruby
# frozen_string_literal: true

bind "tcp://#{ENV.fetch('BIND', '127.0.0.1')}:#{ENV.fetch('PORT', '3000')}"
threads 1, 8
environment ENV.fetch('RACK_ENV', 'development')
```

- [ ] **Step 2: Write `lib/cgminer_manager/server.rb`** (modeled after `cgminer_monitor/lib/cgminer_monitor/server.rb`)

```ruby
# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'
require 'rack'

module CgminerManager
  class Server
    def initialize(config)
      @config = config
      @stop   = Queue.new
    end

    def run
      install_signal_handlers

      HttpApp.monitor_url  = @config.monitor_url
      HttpApp.miners_file  = @config.miners_file
      HttpApp.stale_threshold_seconds = @config.stale_threshold_seconds
      HttpApp.pool_thread_cap = @config.pool_thread_cap

      Logger.info(event: 'server.start', pid: Process.pid,
                  bind: @config.bind, port: @config.port)

      launcher = build_puma_launcher
      puma_thread = Thread.new do
        launcher.run
      rescue Exception => e # rubocop:disable Lint/RescueException
        Logger.error(event: 'puma.crash', error: e.class.to_s, message: e.message)
        @stop << 'puma_crash'
      end

      reinstall_signal_handlers

      signal = @stop.pop
      Logger.info(event: 'server.stopping', signal: signal)

      launcher.stop
      puma_thread.join(@config.shutdown_timeout)
      Logger.info(event: 'server.stopped')
      0
    end

    private

    def install_signal_handlers
      %w[INT TERM].each { |s| trap(s) { @stop << s } }
    end

    def reinstall_signal_handlers
      install_signal_handlers
    end

    def build_puma_launcher
      puma_config = Puma::Configuration.new do |user_config|
        user_config.bind("tcp://#{@config.bind}:#{@config.port}")
        user_config.threads(1, 8)
        user_config.environment(@config.rack_env)
        user_config.app(Rack::Builder.new { run HttpApp.new }.to_app)
      end
      Puma::Launcher.new(puma_config, log_writer: Puma::LogWriter.null)
    end
  end
end
```

- [ ] **Step 3: Require from top-level**

```ruby
require_relative 'cgminer_manager/server'
```

- [ ] **Step 4: Commit**

```bash
git add lib/cgminer_manager/server.rb config/puma.rb lib/cgminer_manager.rb
git commit -m "feat(server): Puma launcher with signal-driven graceful shutdown"
```

### Task 5.2: `cli.rb` + `bin/cgminer_manager`

**Files:**
- Create: `lib/cgminer_manager/cli.rb`
- Create: `bin/cgminer_manager`
- Modify: `lib/cgminer_manager.rb`

- [ ] **Step 1: Write `lib/cgminer_manager/cli.rb`**

```ruby
# frozen_string_literal: true

module CgminerManager
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      verb = argv.shift
      case verb
      when 'run'     then cmd_run
      when 'doctor'  then cmd_doctor
      when 'version' then cmd_version
      else
        warn "unknown verb: #{verb.inspect}"
        warn 'usage: cgminer_manager {run|doctor|version}'
        64
      end
    rescue ConfigError => e
      warn "config error: #{e.message}"
      2
    end

    private

    def cmd_run
      config = Config.from_env
      Logger.format = config.log_format
      Logger.level  = config.log_level
      Server.new(config).run
    end

    def cmd_doctor
      config = Config.from_env
      failures = []

      miners = config.load_miners
      client = MonitorClient.new(base_url: config.monitor_url, timeout_ms: 2000)

      begin
        monitor_miners = client.miners[:miners]
        puts "  monitor /v2/miners: OK (#{monitor_miners.size} miner(s))"
      rescue MonitorError => e
        failures << "monitor unreachable: #{e.message}"
      end

      miners.each do |host, port|
        id = "#{host}:#{port}"
        miner = CgminerApiClient::Miner.new(host, port)
        if miner.available?
          puts "  cgminer #{id}: reachable"
        else
          failures << "cgminer #{id} unreachable"
        end

        next unless monitor_miners

        unless monitor_miners.any? { |m| m[:id] == id }
          failures << "miner #{id} in miners.yml but not in monitor /v2/miners"
        end
      end

      if failures.empty?
        puts 'doctor: all checks passed'
        0
      else
        failures.each { |f| warn "  FAIL: #{f}" }
        1
      end
    end

    def cmd_version
      puts CgminerManager::VERSION
      0
    end
  end
end
```

- [ ] **Step 2: Write `bin/cgminer_manager`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'cgminer_manager'

exit(CgminerManager::CLI.run(ARGV))
```

Make it executable:

```bash
chmod +x bin/cgminer_manager
```

- [ ] **Step 3: Require from top-level**

```ruby
require_relative 'cgminer_manager/cli'
```

- [ ] **Step 4: Commit**

```bash
git add lib/cgminer_manager/cli.rb bin/cgminer_manager lib/cgminer_manager.rb
git commit -m "feat(cli): run/doctor/version verbs"
```

### Task 5.3: `cli_spec.rb` — smoke-test the three verbs

**Files:**
- Create: `spec/cgminer_manager/cli_spec.rb`

- [ ] **Step 1: Write tests**

```ruby
# frozen_string_literal: true

require 'open3'

RSpec.describe 'bin/cgminer_manager', type: :integration do
  def run_cli(*args, env: {})
    Open3.capture3(env, 'bundle', 'exec', 'bin/cgminer_manager', *args,
                   chdir: File.expand_path('../..', __dir__))
  end

  describe 'version' do
    it 'prints the version and exits 0' do
      stdout, _stderr, status = run_cli('version')
      expect(status.exitstatus).to eq(0)
      expect(stdout).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe 'unknown verb' do
    it 'exits 64' do
      _stdout, _stderr, status = run_cli('banana')
      expect(status.exitstatus).to eq(64)
    end
  end

  describe 'doctor' do
    it 'exits non-zero when monitor is unreachable' do
      path = File.join(Dir.mktmpdir, 'miners.yml')
      File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
      env = {
        'CGMINER_MONITOR_URL' => 'http://localhost:65500',
        'MINERS_FILE'         => path,
        'SESSION_SECRET'      => 'x' * 64
      }
      _stdout, _stderr, status = run_cli('doctor', env: env)
      expect(status.exitstatus).not_to eq(0)
    end
  end
end
```

- [ ] **Step 2: Run, confirm pass**

```bash
bundle exec rspec spec/cgminer_manager/cli_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add spec/cgminer_manager/cli_spec.rb
git commit -m "test(cli): version/doctor/unknown-verb"
```

### Task 5.4: `full_boot_spec.rb`

**Files:**
- Create: `spec/integration/full_boot_spec.rb`

- [ ] **Step 1: Write test**

```ruby
# frozen_string_literal: true

require 'net/http'
require 'socket'

RSpec.describe 'full boot', type: :integration do
  it 'starts the Server, serves /healthz, and stops gracefully' do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")

    env = {
      'CGMINER_MONITOR_URL' => 'http://127.0.0.1:65501',
      'MINERS_FILE'         => path,
      'SESSION_SECRET'      => 'x' * 64,
      'PORT'                => '6123',
      'BIND'                => '127.0.0.1',
      'SHUTDOWN_TIMEOUT'    => '3'
    }
    pid = spawn(env, 'bundle', 'exec', 'bin/cgminer_manager', 'run',
                chdir: File.expand_path('../..', __dir__))

    # Wait for the server to accept a TCP connection on the bind address,
    # up to a hard deadline. We use a tight connect probe (50ms connect
    # timeout) so we can retry quickly without sleeping much.
    deadline = Time.now + 15
    until Time.now >= deadline
      begin
        TCPSocket.new('127.0.0.1', 6123).close
        break
      rescue Errno::ECONNREFUSED
        # Not yet bound; retry on next loop iteration.
        Thread.pass
      end
    end
    raise 'server did not bind within deadline' if Time.now >= deadline

    response = Net::HTTP.get_response(URI('http://127.0.0.1:6123/healthz'))
    expect([200, 503]).to include(response.code.to_i)

    Process.kill('TERM', pid)
    _, status = Process.wait2(pid)
    expect(status.exitstatus).to eq(0)
  end
end
```

- [ ] **Step 2: Run, confirm pass**

```bash
bundle exec rspec spec/integration/full_boot_spec.rb
```

Expected: 1 example, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/full_boot_spec.rb
git commit -m "test(integration): full server boot + graceful shutdown"
```

---

## Phase 6 — Packaging & documentation

### Task 6.1: `Dockerfile` + `docker-compose.yml`

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.yml`
- Create: `.dockerignore`

- [ ] **Step 1: Write `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

FROM ruby:4.0-slim AS builder

WORKDIR /app
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential git && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock cgminer_manager.gemspec ./
COPY lib/cgminer_manager/version.rb lib/cgminer_manager/version.rb
RUN bundle config set --local deployment 'true' \
 && bundle config set --local without 'development test' \
 && bundle install

COPY . .

FROM ruby:4.0-slim

WORKDIR /app
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    tzdata && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT='development test'
EXPOSE 3000

ENTRYPOINT ["bundle", "exec", "bin/cgminer_manager"]
CMD ["run"]
```

- [ ] **Step 2: Write `.dockerignore`**

```
.git
.github
spec
tmp
log
docs
app
test
config/miners.yml
config/mongoid.yml
```

- [ ] **Step 3: Write `docker-compose.yml`**

```yaml
services:
  mongo:
    image: mongo:7
    volumes:
      - mongo_data:/data/db

  monitor:
    image: ghcr.io/jramos/cgminer_monitor:latest
    depends_on: [mongo]
    environment:
      CGMINER_MONITOR_MONGO_URL: mongodb://mongo:27017/cgminer_monitor
      CGMINER_MONITOR_HTTP_HOST: 0.0.0.0
    volumes:
      - ./config/miners.yml:/app/config/miners.yml:ro

  manager:
    build: .
    depends_on: [monitor]
    ports: ['3000:3000']
    environment:
      CGMINER_MONITOR_URL: http://monitor:9292
      BIND: 0.0.0.0
      SESSION_SECRET: ${SESSION_SECRET:?set SESSION_SECRET in your environment}
    volumes:
      - ./config/miners.yml:/app/config/miners.yml:ro

volumes:
  mongo_data:
```

- [ ] **Step 4: Build to verify**

```bash
docker build -t cgminer_manager:dev .
```

Expected: successful build.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile docker-compose.yml .dockerignore
git commit -m "chore: multi-stage Dockerfile and docker-compose stack"
```

### Task 6.2: Rewrite `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README content**

```markdown
# cgminer_manager

Web UI for operating cgminer rigs. Displays data fetched from [`cgminer_monitor`](https://github.com/jramos/cgminer_monitor) and issues pool-management commands to miners via [`cgminer_api_client`](https://github.com/jramos/cgminer_api_client).

## Requirements

- Ruby 3.2+ (4.0.2 recommended; see `.ruby-version`)
- A running `cgminer_monitor` instance (MIN_MONITOR_VERSION or newer) exposing `/v2/*`
- MongoDB (used by `cgminer_monitor`, not directly by this service)

## Quick start (Docker)

```bash
export SESSION_SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
cp config/miners.yml.example config/miners.yml
docker compose up
```

Open http://localhost:3000.

## Manual install

```bash
git clone https://github.com/jramos/cgminer_manager.git
cd cgminer_manager
bundle install
cp config/miners.yml.example config/miners.yml
# point at a running cgminer_monitor:
export CGMINER_MONITOR_URL=http://localhost:9292
export SESSION_SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
bin/cgminer_manager doctor
bin/cgminer_manager run
```

## Configuration

All settings come from environment variables.

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `CGMINER_MONITOR_URL` | yes | — | Base URL for `cgminer_monitor` (e.g., `http://localhost:9292`) |
| `MINERS_FILE` | | `config/miners.yml` | YAML list of `{host, port}` entries |
| `PORT` | | `3000` | Listening port |
| `BIND` | | `127.0.0.1` | Listening interface |
| `SESSION_SECRET` | yes in production | generated in dev | Signs session cookies (CSRF) |
| `LOG_FORMAT` | | `text` (dev), `json` (prod) | |
| `LOG_LEVEL` | | `info` | `debug`, `info`, `warn`, `error` |
| `STALE_THRESHOLD_SECONDS` | | `300` | Tile "updated Xm ago" warning threshold |
| `SHUTDOWN_TIMEOUT` | | `10` | Seconds to wait for Puma to stop |

## CLI

- `bin/cgminer_manager run` — start the server.
- `bin/cgminer_manager doctor` — verify `miners.yml`, cgminer reachability, and monitor `/v2/miners`.
- `bin/cgminer_manager version` — print version.

## Development

```bash
bundle install
bundle exec rake  # rubocop + rspec
```

## Security posture

Default bind is `127.0.0.1`. The service is designed for secure local networks; to expose it beyond localhost, put it behind a reverse proxy that provides authentication.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for Sinatra era"
```

### Task 6.3: `MIGRATION.md`

**Files:**
- Create: `MIGRATION.md`

- [ ] **Step 1: Write**

```markdown
# Migrating from cgminer_manager 0.x (Rails) to 1.0 (Sinatra)

## Prerequisites

- **Upgrade `cgminer_monitor` first.** You need a monitor release exposing `/v2/*` with the companion graph-metric endpoints. The legacy (Rails-engine) monitor has no `/v2/*`; manager 1.0 will fail startup against it.
- **Ruby 3.2 or later.** The `.ruby-version` file pins 4.0.2.

## Framework change

- Rails 4.2 → Sinatra + Puma. There is no `rails server`, no `config/environments/`, no asset pipeline.
- `rake server` → `bin/cgminer_manager run`.
- Asset precompile step is gone; JS/CSS live under `public/` and are served directly.

## Configuration changes

- `config/mongoid.yml` — **removed.** Manager no longer connects to MongoDB. Delete your copy.
- `config/miners.yml` — **unchanged.** Same `{host, port}` shape.
- Environment variables — see README "Configuration" table. `CGMINER_MONITOR_URL` and `SESSION_SECRET` are new required settings.

## URL changes

- `/miner/0` → `/miner/10.0.0.5%3A4028` (URL-encoded `host:port`). Array-index routes are gone; they silently corrupted bookmarks on `miners.yml` reorder.
- All existing bookmarks break one-time. Update them after the cutover.

## Feature removals

- `POST /manager/run` and `POST /miner/:id/run` arbitrary-command endpoints are gone. The typed pool-management actions (add / disable / enable / remove / save) remain via the UI.
  - If you relied on `run` for ad-hoc command execution, use `cgminer_api_client` from IRB:
    ```ruby
    require 'cgminer_api_client'
    miner = CgminerApiClient::Miner.new('10.0.0.5', 4028)
    miner.query(:version)
    ```

## `/api/v1/ping.json`

Unchanged shape: `{timestamp, available_miners, unavailable_miners}`. Data source is now cgminer-direct via `cgminer_api_client` (same as before Rails; explicitly independent of monitor so a monitor outage does not cause the probe to go red).

## Recommended cutover ritual

1. Upgrade `cgminer_monitor` to MIN_MONITOR_VERSION.
2. Verify: `curl http://<monitor>/v2/miners` returns 200 JSON.
3. On the manager host, `bin/cgminer_manager doctor` and confirm every check passes.
4. Stop old manager, start `bin/cgminer_manager run`.

## Rollback

The pre-1.0 Rails app remains at the `v0-legacy` git tag (cut just before the Rails unmount commit). To roll back:

```bash
git checkout v0-legacy
# restore the old Rails boot chain; reinstall bundle with old Gemfile
```

This works until the separate "delete Rails tree" follow-up PR lands. After that, `v0-legacy` remains but the tree is gone from HEAD.
```

- [ ] **Step 2: Commit**

```bash
git add MIGRATION.md
git commit -m "docs: MIGRATION.md for Rails → Sinatra cutover"
```

### Task 6.4: `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Write**

```markdown
# Changelog

## [1.0.0] — unreleased

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
- RSpec + WebMock test suite with FakeCgminer integration; GitHub Actions CI (Ruby 3.2 / 3.3 / 3.4 / 4.0 + head).

### Changed
- Ruby floor: **3.2** (gemspec), pinned to **4.0.2** in `.ruby-version`.
- Miner URL scheme: `host:port` (URL-encoded) replaces the array-index scheme. Bookmarks from 0.x break one-time.
- Graph endpoints now reshape monitor's `{fields, data}` envelope to the `[[ts, v1, v2, ...]]` shape `graph.js` expects.

### Removed
- Rails 4.2, Mongoid 4, Thin, therubyracer, Sprockets, jquery-rails, sass-rails, coffee-rails.
- `config/mongoid.yml` (manager no longer connects to MongoDB).
- Arbitrary-command endpoints `POST /manager/run` and `POST /miner/:id/run`.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: CHANGELOG.md 1.0.0 entry"
```

---

## Phase 7 — Unmount Rails, tag v0-legacy, cut 1.0.0

### Task 7.1: Confirm `v0-legacy` tag exists on develop (created in Pre-Phase 0)

**Files:**
- (git only)

- [ ] **Step 1: Verify the tag is present on `develop`'s pre-modernization commit**

```bash
git show-ref --tags v0-legacy
```

Expected: a SHA matching the develop commit from before this branch was created. If missing (e.g. plan started with Phase 0), return to Pre-Phase 0 and create it.

- [ ] **Step 2: Delete `config/mongoid.yml.example`** (explicitly; MIGRATION.md tells operators to remove their copy)

```bash
git rm config/mongoid.yml.example
git commit -m "chore: remove mongoid.yml.example (manager no longer uses Mongo)"
```

### Task 7.2: Unmount Rails from `config.ru`

**Files:**
- Modify: `config.ru`

- [ ] **Step 1: Replace Rails boot with Sinatra rackup**

```ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'cgminer_manager'

run CgminerManager::HttpApp
```

- [ ] **Step 2: Smoke-test via rackup**

```bash
bundle exec rackup -p 3123 &
sleep 2
curl -sS http://127.0.0.1:3123/healthz
kill %1
```

Expected: 200 or 503 JSON body; no tracebacks.

- [ ] **Step 3: Commit**

```bash
git add config.ru
git commit -m "chore: unmount Rails from config.ru; boot Sinatra HttpApp"
```

### Task 7.3: Set version to 1.0.0 and push tag

**Files:**
- Modify: `lib/cgminer_manager/version.rb`

- [ ] **Step 1: Update VERSION**

```ruby
# frozen_string_literal: true

module CgminerManager
  VERSION = '1.0.0'
end
```

- [ ] **Step 2: Run full `rake`**

```bash
bundle exec rake
```

Expected: rubocop green, rspec green, coverage ≥90%.

- [ ] **Step 3: Commit and tag**

```bash
git add lib/cgminer_manager/version.rb
git commit -m "chore: release 1.0.0"
git tag -a v1.0.0 -m "Sinatra port; drop Mongo; /v2/* HTTP consumption"
```

- [ ] **Step 4: Push branch and tags**

```bash
git push -u origin modernize/sinatra-port
git push origin v0-legacy v1.0.0
```

### Task 7.4: Open PR to `develop`

- [ ] **Step 1: Open a PR**

```bash
gh pr create --base develop --title "Modernize cgminer_manager: Sinatra port (1.0.0)" --body "$(cat <<'EOF'
## Summary
- Full port of cgminer_manager from Rails 4.2 to Sinatra + Puma.
- Drops MongoDB; reads all display data via HTTP from cgminer_monitor's /v2/*.
- Keeps cgminer_api_client 0.3.x for the command plane; rewrites pool-management with a three-state PoolActionResult.
- New CI, RuboCop, RSpec + WebMock + FakeCgminer integration suite, Docker packaging.

## Test plan
- [ ] `bundle exec rake` green locally
- [ ] GH Actions lint / test matrix / integration all green
- [ ] `docker compose up` boots manager + monitor + mongo
- [ ] `bin/cgminer_manager doctor` passes against a running monitor
- [ ] Dashboard renders at http://localhost:3000; per-miner tiles show expected values
- [ ] Pool management: disable + remove round-trips against a real cgminer produce expected PoolActionResult entries
- [ ] `/api/v1/ping.json` shape matches legacy; works when monitor is down

See `docs/superpowers/specs/2026-04-16-cgminer_manager-modernization-design.md` and `MIGRATION.md`.
EOF
)"
```

- [ ] **Step 2: Post PR URL back to user**

---

## Deferred (follow-up PR after soak)

**Delete the Rails tree.** Once 1.0.0 has soaked for a release cycle with no critical regressions:

- Remove `app/`, `config/application.rb`, `config/environment.rb`, `config/environments/`, `config/routes.rb`, `config/boot.rb`, `lib/tasks/`, `test/`, and any Rails-specific initializers.
- Update `.rubocop.yml` to drop the `Exclude` entries for those paths.
- Cut 1.1.0.

This deletion intentionally does not happen in the 1.0.0 PR — it preserves `git bisect` through the cutover window and keeps `v0-legacy` meaningful as a rollback target.
