# Workflows

Four runtime flows cover essentially everything: startup, dashboard rendering, admin/pool write operations, and graceful shutdown. Plus three dev workflows: running tests, regenerating screenshots, and refreshing monitor fixtures.

## 1. Startup (`cgminer_manager run`)

```mermaid
sequenceDiagram
    participant CLI as bin/cgminer_manager
    participant Config
    participant Logger
    participant Server
    participant HttpApp
    participant Puma as Puma::Launcher
    participant PumaT as Puma thread

    CLI->>Config: Config.from_env
    alt invalid env
        Config--xCLI: raise ConfigError
        CLI--xCLI: warn 'config error:', exit 2
    end
    CLI->>Logger: Logger.format= / level= from config
    CLI->>Server: Server.new(config) and .run

    Server->>Server: install_signal_handlers (trap INT/TERM → @stop)
    Server->>HttpApp: set class attrs (monitor_url, miners_file, etc.)
    Server->>HttpApp: reset_configured_miners!
    Server->>Logger: Logger.info 'server.start'

    Server->>Server: @booted = Queue.new
    Server->>Puma: build launcher with raise_exception_on_sigterm false
    Server->>Puma: launcher.events.on_booted { @booted << true }
    Server->>PumaT: Thread.new { launcher.run }
    PumaT->>PumaT: setup_signals (overwrites our INT/TERM!)
    PumaT->>PumaT: bind listener on BIND:PORT
    PumaT->>Server: @booted << true
    Server->>Server: @booted.pop (wakes)
    Server->>Server: install_signal_handlers again
    Server->>Server: @stop.pop (block until signal)

    Note over HttpApp,PumaT: app is now serving, goto request lifecycle
```

**Two signal-handler installs?** Yes. Puma's `setup_signals` synchronously overwrites SIGTERM/SIGINT handlers inside its thread. We install first so a signal arriving during boot lands in `@stop`, and install again after `@booted.pop` to reclaim those signals.

**Two things can cause `cmd_run` to exit non-zero at boot:**
- `ConfigError` — CLI rescues, exits 2.
- `StandardError` escaping `Server#run` — propagates out, unhandled. Process dies and the supervisor restarts.

## 2. Dashboard render (`GET /`)

```mermaid
sequenceDiagram
    participant Browser
    participant Puma
    participant HttpApp
    participant MC as MonitorClient
    participant Workers as snapshot worker pool (thread_cap)
    participant Monitor as cgminer_monitor
    participant Adapter as SnapshotAdapter
    participant HAML

    Browser->>Puma: GET /
    Puma->>HttpApp: dispatch to '/' route
    HttpApp->>HttpApp: @request_started_at = Time.now

    HttpApp->>ViewModels: ViewModels.build_dashboard(monitor_client:, configured_miners:, ...)
    ViewModels->>MC: monitor_client.miners
    MC->>Monitor: GET /v2/miners
    alt monitor reachable
        Monitor-->>MC: {miners: [...]}
        MC->>Logger: 'monitor.call' url=/v2/miners status=200 duration_ms=...
        MC-->>ViewModels: parsed miners
        ViewModels->>ViewModels: fetch_snapshots_for(monitor_client, miners, cap)

        par per-miner parallel (up to pool_thread_cap)
            ViewModels->>Workers: spawn worker with queue
            Workers->>MC: summary, devices, pools, stats (four calls)
            MC->>Monitor: four GETs per miner
            Monitor-->>MC: four responses
            MC-->>Workers: four parsed snapshots (each may be {error: ...} on rescue)
            Workers-->>ViewModels: miner_id => {summary:, devices:, pools:, stats:}
        end

    else monitor down
        MC--xViewModels: MonitorError
        ViewModels->>ViewModels: banner='data source unavailable', miners=fallback from yml
    end

    ViewModels-->>HttpApp: @view = {miners:, snapshots:, banner:, stale_threshold:}
    HttpApp->>Adapter: SnapshotAdapter.build_miner_data(configured_miners, snapshots)
    Adapter->>Adapter: per-type: sanitize keys, wrap in legacy [{type: inner}] shape
    Adapter-->>HttpApp: @miner_data
    HttpApp->>ViewModels: ViewModels.build_view_miner_pool(monitor_miners, configured_miners:) → @miner_pool
    HttpApp->>HAML: haml :'manager/index' with @miner_pool, @miner_data, @bad_chain_elements, @view
    HAML->>HAML: render layout, _header, manager/index (Summary/Miner Pool/Admin tabs),
    HAML-->>HttpApp: HTML
    HttpApp->>Logger: after-filter: 'http.request' path=/ status=200 duration_ms=...
    HttpApp-->>Puma: 200 HTML
    Puma-->>Browser: response
```

**Key observations:**
- A dashboard render with 10 miners performs 1 + 10×4 = 41 HTTP calls to monitor. With `POOL_THREAD_CAP=8` (default), the 40 per-miner calls run in parallel batches of 8.
- Each of the 40 per-miner calls independently catches `MonitorError` and turns it into `{error: "..."}`. A single bad tile doesn't fail the whole dashboard.
- The top-level `ViewModels.build_dashboard` rescue handles the "can't even enumerate miners" case — it falls back to `configured_miners` from `miners.yml` with no availability data and sets a banner.
- `@miner_pool` drives the "Miner Pool" tab (availability status from monitor). `@miner_data` drives the "Summary" tab (per-miner hashrate and devices tables). Graph canvases on Summary pull their data from `/graph_data/:metric` via Chart.js after page load.

## 3. Pool management flow (`POST /manager/manage_pools`)

```mermaid
sequenceDiagram
    participant Browser
    participant Puma
    participant CSRF as ConditionalAuthenticityToken
    participant HttpApp
    participant PM as PoolManager
    participant Workers as pool worker pool
    participant Miners as cgminer instances

    Browser->>Puma: POST /manager/manage_pools<br/>action_name=disable pool_index=1 authenticity_token=...
    Puma->>CSRF: validate token (not admin path, AdminAuth skipped)
    CSRF-->>HttpApp: dispatch

    HttpApp->>HttpApp: action_name='disable', pool_index=1
    HttpApp->>HttpApp: build_pool_manager_for_all
    HttpApp->>PM: pm.disable_pool(pool_index: 1)

    PM->>PM: run_each { |miner| run_verified(miner) { ... } }
    par per-miner parallel (up to thread_cap)
        Workers->>Miners: miner.disablepool(1)
        Miners-->>Workers: response or raise

        alt command succeeded
            Workers->>Miners: miner.query(:pools)
            Miners-->>Workers: pool list
            Workers->>Workers: verify_pool_state: find pool 1, check STATUS == 'Disabled'
            alt matches
                Workers->>Miners: miner.query(:save)
                Miners-->>Workers: save response or raise
                Workers-->>PM: MinerEntry(command_status=:ok, save_status=:ok|:failed)
            else mismatch
                Workers-->>PM: MinerEntry(command_status=:indeterminate, save_status=:skipped)
            end
        else command failed
            Workers-->>PM: MinerEntry(command_status=:failed, save_status=:skipped)
        end
    end

    PM-->>HttpApp: PoolActionResult(entries)
    HttpApp->>HAML: render_partial 'shared/manage_pools' with @result
    HAML-->>HttpApp: HTML fragment
    HttpApp-->>Puma: 200 HTML
    Puma-->>Browser: response
```

**Key observations:**
- Every verified pool op runs a post-write query to confirm state. `:indeterminate` is the third result state for "the RPC succeeded but the world isn't what we expect."
- `save_status: :skipped` when the command step failed. No point saving an unchanged state.
- `add_pool` is unverified (cgminer's response doesn't give the new pool index deterministically). `save_status` is always `:skipped` for unverified ops; callers run `save` explicitly.

## 4. Admin flow (`POST /manager/admin/run`)

```mermaid
sequenceDiagram
    participant Browser
    participant Puma
    participant AA as AdminAuth
    participant CSRF as ConditionalAuthenticityToken
    participant HttpApp
    participant Cmdr as CgminerCommander
    participant Workers as commander worker pool
    participant Miners as cgminer instances

    Browser->>Puma: POST /manager/admin/run<br/>command=stats args= scope=all<br/>authenticity_token=... (or Basic Auth)
    Puma->>AA: path matches /(manager|miner/.../admin)/

    alt Basic Auth configured
        alt valid
            AA->>AA: env['cgminer_manager.admin_authed'] = true
            AA-->>CSRF: continue
        else invalid
            AA->>Logger: 'admin.auth_failed' reason=...
            AA-->>Browser: 401 + WWW-Authenticate
        end
    else unconfigured
        AA-->>CSRF: pass through (admin_authed = false)
    end

    CSRF->>CSRF: admin_authed? skip token : validate token
    alt token missing/invalid (and no Basic Auth)
        CSRF-->>Browser: 403 Forbidden
    else ok
        CSRF-->>HttpApp: dispatch
    end

    HttpApp->>HttpApp: before-filter: @request_id = SecureRandom.uuid
    HttpApp->>HttpApp: validate command against ADMIN_RAW_COMMAND_PATTERN
    alt pattern mismatch
        HttpApp-->>Browser: 422 'invalid command: ...'
    end
    HttpApp->>HttpApp: scope check
    alt SCOPE_RESTRICTED_VERBS + scope=all
        HttpApp->>Logger: 'admin.scope_rejected' request_id=... command=... scope=all
        HttpApp-->>Browser: 422 "command 'X' cannot target scope=all"
    end
    HttpApp->>HttpApp: build_commander_for_all or _for([scope])
    HttpApp->>Logger: 'admin.raw_command' request_id=... command=... args=... scope=...

    HttpApp->>Cmdr: cmd.raw!(command: ..., args: ...)
    Cmdr->>Cmdr: fan_out_write { |m| m.query(verb, *positional) }
    par per-miner parallel
        Workers->>Miners: Miner.query(verb, *args)
        Miners-->>Workers: response or raise
        Workers->>Workers: wrap in FleetWriteEntry(ok/failed)
    end
    Cmdr-->>HttpApp: FleetWriteResult

    HttpApp->>Logger: 'admin.result' request_id=... ok_count=N failed_count=M duration_ms=...
    HttpApp->>HAML: render_admin_result(result)
    HAML-->>HttpApp: HTML fragment (shared/_fleet_write)
    HttpApp-->>Puma: 200 HTML
    Puma-->>Browser: response
```

**Key observations:**
- Entry (`admin.raw_command` or `admin.command`), rejection (`admin.scope_rejected`, `admin.auth_failed`), and exit (`admin.result`) events all share the same `request_id`. Grep logs by `request_id` to see one operation end-to-end.
- Typed-allowlist admin routes (`/manager/admin/:command`) skip the `ADMIN_RAW_COMMAND_PATTERN` check (they use an enum match instead) and don't have `args` — they map directly to the commander's named methods.

## 5. Graceful shutdown

```mermaid
flowchart TD
    A[Signal or Puma crash] --> B[push to @stop Queue]
    B --> C[Main thread unblocks from @stop.pop]
    C --> D[Logger.info 'server.stopping']
    D --> E[launcher.stop]
    E --> F[puma_thread.join with shutdown_timeout]
    F -->|clean| G[Logger.info 'server.stopped']
    F -.timeout.- G
    G --> H[Server#run returns 0]
    H --> I[CLI#run returns 0]
    I --> J[bin/cgminer_manager exits 0]

    X[Puma thread raises internally] --> Y[rescue Exception]
    Y --> Z[Logger.error 'puma.crash']
    Z --> AA[push 'puma_crash' to @stop]
    AA --> C
```

`puma_thread.join(shutdown_timeout)` returns nil if Puma hasn't stopped within `SHUTDOWN_TIMEOUT` seconds; we move on regardless. Worst case the supervisor sends SIGKILL and Puma dies mid-request.

## 6. Local dev: running tests

```sh
bundle install
bundle exec rake                                   # rubocop + rspec (full suite)
bundle exec rspec --tag ~integration               # unit only (CI matrix runs this)
bundle exec rspec --tag integration                # integration only
bundle exec rspec path/to/spec.rb:123              # single example
bundle exec rubocop                                # lint only
bundle exec rubocop -A                             # lint + auto-correct
```

Coverage via SimpleCov, enforced at the default rake task (`ENFORCE_COVERAGE=1` implicit). Reports land in `coverage/`.

No MongoDB or live cgminer required locally. Integration specs use:
- **WebMock** to stub monitor's `/v2/*` (see `spec/support/monitor_stubs.rb`).
- **FakeCgminer** TCP server (see `spec/support/fake_cgminer.rb`) for the few specs that exercise the cgminer side directly.

## 7. Regenerating screenshots

The `dev/screenshots/` harness is separate from the spec suite. It spins up a **real** cgminer fleet (6 TCP listeners at `127.0.0.1:40281..40286`), a fake monitor, and a manager process, then drives Playwright through the UI to capture PNGs for `public/screenshots/`.

```sh
cd dev/screenshots
./boot.sh       # launches fake_cgminer_fleet, fake_monitor, manager
# ... runs Playwright scenario.rb ...
./teardown.sh   # cleanly shuts everything down
```

Logs land in `dev/screenshots/.run/*.log`. See `dev/screenshots/README.md` for details.

## 8. Refreshing monitor fixtures

`Rakefile` provides `rake spec:refresh_monitor_fixtures` for capturing live monitor responses into `spec/fixtures/monitor/*.json`:

```sh
CGMINER_MONITOR_URL=http://monitor.local:9292 \
  CGMINER_FIXTURE_MINER_ID=192.168.1.10:4028 \
  bundle exec rake spec:refresh_monitor_fixtures
```

Fetches `/v2/miners`, per-miner `{summary, devices, pools, stats}`, `/v2/graph_data/hashrate`, and `/v2/healthz` for the named miner. Writes them as `miners.json`, `summary.json`, etc. Useful after a monitor version bump when the envelope shape changes.

## 9. Release

Not automated. On a clean `master`:

```sh
bundle exec rake                                    # must pass
# bump VERSION in lib/cgminer_manager/version.rb
# update CHANGELOG.md (Keep-a-Changelog format)
git commit -am "Release vX.Y.Z"
gem build cgminer_manager.gemspec                   # produces cgminer_manager-X.Y.Z.gem
gem push cgminer_manager-X.Y.Z.gem                  # requires 2FA (rubygems_mfa_required=true)
git tag vX.Y.Z
git push origin master vX.Y.Z
```

Docker image is not currently pushed by CI. If that changes later, it'd be a separate workflow triggered on tag push.

## 10. Docker Compose dev stack

`docker-compose.yml` wires manager, monitor, and Mongo together:

```sh
export SESSION_SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
cp config/miners.yml.example config/miners.yml
docker compose up
```

Opens on `http://localhost:3000`. See README for Basic Auth env vars to add when exposing beyond localhost.
