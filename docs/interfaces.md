# Interfaces

`cgminer_manager` has four surfaces:

1. The **CLI** (`cgminer_manager` binary).
2. The **environment-variable config**.
3. The **`miners.yml`** file.
4. The **HTTP API + UI** served by the embedded Puma.

And it consumes two external interfaces:

5. **`cgminer_monitor`'s `/v2/*` API** over HTTP.
6. **cgminer instances** directly over TCP via `cgminer_api_client`.

## 1. CLI

### Binary

```
cgminer_manager <command>
```

### Subcommands

| Command | Purpose | Exit codes |
|---|---|---|
| `run` | Start the Sinatra service in the foreground. Blocks until SIGTERM/SIGINT. | `0` clean shutdown; `2` config error from `Config.from_env` |
| `doctor` | Check monitor reachability, each cgminer's TCP reachability, and consistency between `miners.yml` and monitor's `/v2/miners`. Read-only. | `0` all checks passed, `1` at least one failure, `2` config error |
| `version` | Print `CgminerManager::VERSION`. | `0` |
| anything else / missing | Print `unknown verb:` to stderr + usage line. | `64` |

Exit code semantics note: `2` is **not** a standard sysexits(3) code — `cgminer_monitor` uses `78` (`EX_CONFIG`) for the equivalent failure. The choice here predates that convergence and we've kept it for compatibility with existing systemd units.

### Output streams

**stdout:**
- `run`: structured log lines. Format controlled by `LOG_FORMAT` (`json` by default in production, `text` by default in development).
- `doctor`: human-readable check output (`  monitor /v2/miners: OK (3 miner(s))`, `  cgminer 192.168.1.10:4028: reachable`, etc.), then `doctor: all checks passed` on success.
- `version`: one line.

**stderr:**
- `unknown verb: …` + usage line.
- `config error: <msg>` — `ConfigError` rescued at the CLI boundary.
- `doctor`: `  FAIL: …` lines listed after the positive checks on failure.
- One-off dev-only warning from `Config.resolve_session_secret`: `[cgminer_manager] SESSION_SECRET unset; generating ephemeral secret (dev only)` — not structured, written with `warn` before the logger is configured.

Library code inside `lib/` never writes to `$stderr` directly — everything flows through `CgminerManager::Logger` to stdout. The only direct `warn` calls are in the CLI and in the session-secret fallback.

### `doctor` detail

The `doctor` subcommand performs three checks:

1. Reach `cgminer_monitor` at `CGMINER_MONITOR_URL` via `GET /v2/miners`. Record the miner count.
2. For each entry in `miners.yml`: open a TCP socket to `host:port` (via `CgminerApiClient::Miner#available?`) and report reachable or not.
3. For each entry in `miners.yml`: check that the same `host:port` appears in monitor's `/v2/miners` list. Missing entries are an explicit failure.

Non-zero exit on any failure. No attempt to mutate anything.

## 2. Environment-variable config

Parsed once at boot by `Config.from_env`, validated in `Config#validate!`. Defaults in parentheses.

| Variable | Purpose |
|---|---|
| `CGMINER_MONITOR_URL` | Base URL of cgminer_monitor (e.g. `http://localhost:9292`). **Required.** No default. |
| `MINERS_FILE` | Path to miners YAML. Default `config/miners.yml`. Must exist at boot. |
| `PORT` | Puma bind port. Default `3000`. |
| `BIND` | Puma bind address. Default `127.0.0.1`. |
| `SESSION_SECRET` | Signs session cookies. **Required in production**; dev generates an ephemeral one with a stderr warning. |
| `CGMINER_MANAGER_ADMIN_USER` | Basic Auth username for admin routes. Read per-request by `AdminAuth`. **Required by default** — boot fails unless this + `_PASSWORD` are both set, or `CGMINER_MANAGER_ADMIN_AUTH=off`. |
| `CGMINER_MANAGER_ADMIN_PASSWORD` | Basic Auth password. Paired with `_USER`. **Required by default** (see above). |
| `CGMINER_MANAGER_ADMIN_AUTH` | Set to `off` to deliberately disable admin auth (escape hatch). Default unset. |
| `LOG_FORMAT` | `json` (default in prod) or `text` (default in dev). |
| `LOG_LEVEL` | `debug` / `info` / `warn` / `error`. Default `info`. |
| `STALE_THRESHOLD_SECONDS` | UI staleness badge threshold. Default `300`. |
| `SHUTDOWN_TIMEOUT` | Seconds to wait for Puma to stop after SIGTERM. Default `10`. |
| `MONITOR_TIMEOUT_MS` | HTTP timeout for monitor calls in milliseconds. Default `2000`. |
| `POOL_THREAD_CAP` | Thread cap for `CgminerCommander` + `PoolManager` + dashboard snapshot fan-out. Default `8`. |
| `RACK_ENV` | Passed to Puma and used to gate dev vs. production defaults. Default `development`. |

`Config#validate!` fails hard (raises `ConfigError`, CLI maps to exit 2) on: missing `CGMINER_MONITOR_URL`, missing `miners_file`, unknown `log_format`, unknown `log_level`. Integer parsing errors name the offending env var. `Config.from_env` additionally raises `ConfigError` when admin auth is unconfigured (neither creds set nor `CGMINER_MANAGER_ADMIN_AUTH=off`).

## 3. `miners.yml`

YAML array of miner descriptors. Loaded into `settings.configured_miners` by `Server#configure_http_app` via `HttpApp.parse_miners_file`, and by `Config#load_miners` (used by `doctor`).

```yaml
- host: 192.168.1.10
  port: 4028
- host: 192.168.1.11
  port: 4028
  label: main rig
- host: miner3.local
  # port defaults to 4028
```

| Key | Required | Type | Default |
|---|---|---|---|
| `host` | yes | string | — |
| `port` | no | integer | `4028` |
| `label` | no | string | nil (UI falls back to `host:port`) |

Parsed with `YAML.safe_load_file`. `HttpApp.parse_miners_file` validates the shape: must be a `Array<Hash>` where every entry has a `host` key. Invalid shapes raise `ConfigError`.

## 4. HTTP API + UI

Base URL: `http://<BIND>:<PORT>/` (default `http://127.0.0.1:3000/`).

### Routes

| Method | Path | Purpose | Response type |
|---|---|---|---|
| GET | `/` | Dashboard (Summary / Miner Pool / Admin tabs). | `text/html` |
| GET | `/miner/:miner_id` | Per-miner page (Miner / Devs / Pools / Stats / Admin tabs). `:miner_id` is URL-encoded `host:port`. | `text/html` |
| GET | `/graph_data/:metric` | Dashboard-aggregate graph data. `:metric` ∈ `{hashrate, temperature, availability}`. Optional `since` query (passes through to monitor). | `application/json` |
| GET | `/miner/:miner_id/graph_data/:metric` | Per-miner graph data. Same metric set. | `application/json` |
| POST | `/manager/manage_pools` | Fleet-wide pool op. Params: `action_name` ∈ `{enable, disable, remove, add}`, `pool_index` (for enable/disable/remove), `url`/`user`/`pass` (for add). CSRF-protected. Returns a rendered partial. | `text/html` |
| POST | `/miner/:miner_id/manage_pools` | Per-miner pool op. Same params. CSRF-protected. | `text/html` |
| POST | `/manager/admin/:command` | Typed fleet admin. `:command` ∈ `{version, stats, devs, zero, save, restart, quit}`. CSRF-protected; Basic Auth required by default (or `=off`). | `text/html` |
| POST | `/manager/admin/run` | Raw fleet admin. Params: `command` (matches `ADMIN_RAW_COMMAND_PATTERN`), `args` (comma-separated positional), `scope` (`all` or a configured `host:port`). 422 on pattern mismatch or scope rejection. CSRF-protected; Basic Auth required by default (or `=off`). | `text/html` |
| POST | `/miner/:miner_id/admin/:command` | Typed per-miner admin. Same `:command` set. | `text/html` |
| POST | `/miner/:miner_id/admin/run` | Raw per-miner admin. `scope=all` restriction does not apply (scope is already the one miner). | `text/html` |
| GET | `/api/v1/ping.json` | Legacy probe. Returns `{timestamp, available_miners, unavailable_miners}` from cgminer-direct probes (independent of monitor). | `application/json` |
| GET | `/healthz` | Service health. 200 if miners.yml parses and monitor `/v2/healthz` reachable, else 503 with a `reasons:` array. | `application/json` |

Sinatra route order matches the file order in `http_app.rb`. Named captures (`:miner_id`, `:command`, `:metric`) are standard Sinatra — no custom router.

### CSRF and Basic Auth interaction

All `POST /manager/*` and `POST /miner/*` routes are CSRF-protected via `ConditionalAuthenticityToken`.

Admin routes (`/manager/admin/*`, `/miner/:id/admin/*`) additionally pass through `AdminAuth`. Admin Basic Auth is **required by default as of 1.3.0** (`Config.from_env` fails boot unless configured):

- If `CGMINER_MANAGER_ADMIN_USER` *and* `CGMINER_MANAGER_ADMIN_PASSWORD` are both set (non-empty): require valid Basic Auth. Valid Basic Auth sets `env['cgminer_manager.admin_authed'] = true`, which `ConditionalAuthenticityToken` checks to bypass the token check.
- If creds unset *and* `CGMINER_MANAGER_ADMIN_AUTH=off`: `AdminAuth` passes through. CSRF still applies (browser path).
- If creds unset *and* no escape hatch (post-boot env tampering): 503 `Service Unavailable` with `Content-Type: text/plain` + `admin.auth_misconfigured` log event.
- Precedence: the `=off` escape hatch only fires when creds are unset — creds-set always engages the gate.

Browser clients get the token via `csrf_meta_tag` in the layout and submit it via the `authenticity_token` hidden field. XHR clients can read the token from the meta tag and send it via the `X-CSRF-Token` header. Scripts/curl with valid Basic Auth skip CSRF.

### Raw RPC arg escaping caveat

`POST /manager/admin/run` and `POST /miner/:id/admin/run` pass `args` through `args.to_s.split(',')` before handing the array to `cgminer_api_client`'s `Miner#query`. **Commas inside argument values are not escapable through this form** — the split happens before the gem's own escape pass. Not a practical limitation for any common cgminer verb.

### Scope restrictions

These commands refuse `scope=all` with `422 + admin.scope_rejected` log when hit through `/manager/admin/run`:

- `pgaset`, `ascset` — device clock / voltage tuning.
- `pgarestart`, `ascrestart` — per-device restart with params.
- `pgaenable`, `pgadisable`, `ascenable`, `ascdisable` — device enable/disable.

The UI disables the "all" scope option when the command input matches — but the server-side regex is the defensive layer.

### Graph data response shape

The manager's `/graph_data/:metric` endpoints are a *projection* over monitor's `/v2/graph_data/:metric` response: monitor returns `{miner, metric, since, until, fields: [...], data: [[ts, v1, v2, ...], ...]}`; the manager strips the envelope and returns only the reordered `data` array, with each row columns reordered to a stable projection:

| Metric | Columns returned |
|---|---|
| `hashrate` | `[ts, ghs_5s, ghs_av, device_hardware_pct, device_rejected_pct, pool_rejected_pct, pool_stale_pct]` |
| `temperature` | `[ts, min, avg, max]` |
| `availability` | `[ts, available, configured]` (dashboard) / `[ts, available]` (per-miner) |

If monitor's response is missing a column (e.g., per-miner availability), the projection fills `nil` for that slot. The Chart.js frontend reads the array positions directly.

### 4xx / 5xx responses

- `400 Bad Request` — unknown `action_name` on manage_pools (`halt 400, "unknown action: ..."`, `text/plain`).
- `404 Not Found` — unknown miner_id on per-miner routes, unknown metric on graph_data, unknown command on typed admin. Falls through to the `not_found do` block which renders `views/errors/404.haml` as HTML.
- `422 Unprocessable Entity` — `ADMIN_RAW_COMMAND_PATTERN` mismatch, `SCOPE_RESTRICTED_VERBS` + `scope=all` (with `admin.scope_rejected` log), unknown scope. `text/plain` message.
- `500 Internal Server Error` — unhandled exception in any route. Logs `http.500` with backtrace, renders `views/errors/500.haml`.

### Request logging

Every HTTP request emits an `http.request` log line in the `after` filter with `path`, `method`, `status`, `render_ms`. For admin routes the `before` filter generates a `request_id = SecureRandom.uuid` which threads through the admin audit events (see `architecture.md` → admin audit log schema).

## 5. Upstream: `cgminer_monitor` `/v2/*`

Hard runtime dependency. Read-path data source for the dashboard and per-miner pages.

Endpoints consumed (via `MonitorClient`):

- `GET /v2/miners` — enumerate configured miners on monitor side.
- `GET /v2/miners/:id/{summary,devices,pools,stats}` — per-miner latest snapshots.
- `GET /v2/graph_data/:metric` — time-series for graphs.
- `GET /v2/healthz` — used by our own `/healthz`.

Manager speaks to monitor over plain HTTP with a timeout controlled by `MONITOR_TIMEOUT_MS` (default 2000ms), flowing through `Config#monitor_timeout` → `settings.monitor_timeout_ms` → `MonitorClient.new(timeout_ms:)`. Manager does **not** speak monitor's Prometheus `/metrics` or use its OpenAPI spec; we have our own OpenAPI gap (see `review_notes.md`).

Manager requires `cgminer_monitor` 1.0+ (the release that introduced `/v2/*`). The 0.x Rails-engine monitor has no `/v2/*` and will fail manager's startup `doctor` check.

## 6. Upstream: cgminer via `cgminer_api_client`

Hard runtime dependency (`~> 0.3`). Write-path data source for pool management and admin RPC.

Classes used:
- `CgminerApiClient::Miner.new(host, port)` — one TCP client per request, no connection pooling. The monkey-patched `#to_s` (defined at the top of `http_app.rb`) returns `"host:port"` for display.
- `CgminerApiClient::MinerPool` — not used directly by manager (both `CgminerCommander` and `PoolManager` build their own thread-pool fan-out).

Errors caught and folded into result entries:
- `CgminerApiClient::ConnectionError`
- `CgminerApiClient::TimeoutError`
- `CgminerApiClient::ApiError`

Also caught but re-raised differently:
- `CgminerManager::PoolManagerError::DidNotConverge` (raised by `PoolManager`'s verification helpers, captured into `MinerEntry.command_status = :indeterminate`).

## Structured log schema

Every log line is a JSON object (default in production) or tokenized text. Guaranteed fields: `ts`, `level`, `event`.

Notable events (non-exhaustive):

| Event | Emitter | Fields |
|---|---|---|
| `server.start`, `server.stopping`, `server.stopped` | Server | standard |
| `puma.crash` | Server | `error`, `message` |
| `http.request` | HttpApp (after filter) | `path`, `method`, `status`, `render_ms` |
| `http.500` | HttpApp error handler | `error`, `message`, `backtrace` (first 10) |
| `monitor.call` | MonitorClient | `url`, `status`, `duration_ms` |
| `monitor.call.failed` | MonitorClient | `url`, `error`, `message` |
| `admin.command`, `admin.raw_command` | HttpApp admin routes | `request_id`, `user`, `remote_ip`, `user_agent`, `session_id_hash`, `command`, `scope`, `args` |
| `admin.result` | HttpApp admin routes | `request_id`, `command`, `scope`, `ok_count`, `failed_count`, `elapsed_ms` |
| `admin.scope_rejected` | HttpApp `/admin/run` | `request_id`, `command`, `scope` |
| `admin.auth_failed` | AdminAuth | `reason`, `path`, `remote_ip`, `user_agent` |
| `admin.auth_misconfigured` | AdminAuth | `path`, `remote_ip`, `user_agent` — admin path hit with neither creds nor `=off` (defense-in-depth for post-boot env tampering; boot-time `Config.from_env` should have caught it first). Emits a `503` response. |
