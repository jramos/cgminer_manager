# Logging

`cgminer_manager` emits structured logs via `CgminerManager::Logger.{info,warn,error}(event: '...', ...)`. Every entry is a single-line JSON object on stdout (text mode available for local debugging via `CGMINER_MANAGER_LOG_FORMAT=text`).

The full cross-repo contract — reserved keys, standard key types, complete event catalog, evolution rules, and grep recipes — lives in `cgminer_monitor`:

→ **[cgminer_monitor/docs/log_schema.md](https://github.com/jramos/cgminer_monitor/blob/develop/docs/log_schema.md)**

Consumers and contributors should treat that document as the source of truth.

## Namespaces owned by cgminer_manager

- `admin.*` — admin surface (`admin.command`, `admin.result`, `admin.auth_failed`, `admin.auth_misconfigured`). Construction helpers live in `lib/cgminer_manager/admin_logging.rb`.
- `rate_limit.*` — the per-IP rate limiter (`rate_limit.exceeded`).
- `monitor.*` — manager's HTTP client calls to `cgminer_monitor` (`monitor.call`, `monitor.call.failed`). The prefix names the *dependency*, not the emitter.
- `http.request`, `http.500` — the Rack-level after-filter and the `error Exception` handler in `HttpApp`.

## Namespaces shared with cgminer_monitor

- `server.*` — process lifecycle (`server.start`, `server.stopping`, `server.stopped`, `server.pid_file_written`).
- `reload.*` — SIGHUP hot-reload (`reload.signal_received`, `reload.ok`, `reload.failed`). `reload.partial` is monitor-only within this namespace.
- `puma.*` — Puma thread crashes (`puma.crash`).
- `http.unhandled_error` — uncaught exceptions below the Sinatra error handler (both repos emit).

## House conventions

- **Bare `Logger.warn(...)`** inside `module CgminerManager`. Don't fully-qualify as `CgminerManager::Logger.warn(...)` — module lookup finds the sibling.
- **Scalar `miner:` for a rig id** (`"host:port"`); plural `miners:` for a count. Don't reintroduce `miner_id:`.
- **Timing is `duration_ms` everywhere.** `admin.result` and `http.request` previously used `elapsed_ms` / `render_ms`; that was renamed to match the schema contract. New events should use `duration_ms`.
- **Exceptions serialize as strings.** `error: e.class.to_s`, `message: e.message`, `backtrace: e.backtrace&.first(10)`. Never log an exception object directly.
- **Admin events never log raw credentials.** `admin.command` carries `session_id_hash` (SHA256-hex prefix) and `user` (username), never the raw session id or password.

## Adding a new event

1. Decide the namespace. If it fits under an existing `cgminer_manager`-owned prefix, use that. If not, reserve a new prefix in `cgminer_monitor/docs/log_schema.md` first.
2. Name the event `<namespace>.<action>` (lowercase, dotted, one dot).
3. Reuse standard keys where possible (see schema doc's "Standard keys" table). Minting a new key requires adding a row to that table.
4. Add an entry to the schema doc's event catalog with the required + optional keys.
5. Ship a CHANGELOG `### Changed` entry if the event is new on an existing namespace, or `### Added` if the namespace itself is new.
