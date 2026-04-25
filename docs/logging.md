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

## Audit retention

`cgminer_manager` emits structured JSON to stdout (one event per line; `LOG_FORMAT=json` is the production default). **Durable storage, rotation, and retention are the deployer's responsibility** — handled by the supervisor (systemd / Docker / Kubernetes) or a log shipper, not by the application. The manager has no file sink and no runtime dependency on a log backend; the only contract is that stdout is consumed somewhere.

A built-in rotating-file logger would reinvent what `journald` / `logrotate` / Docker's `json-file` driver / Vector / Fluent-Bit already do well, and create a parallel sink that complicates a single-source-of-truth log pipeline. The application stays narrow; the operator picks the routing.

### What counts as audit-relevant

For audit retention specifically (a stricter set than ops logging), filter on:

- `event` matches `admin.*` — every admin POST. Includes `admin.command`, `admin.result`, `admin.auth_failed`, `admin.auth_misconfigured`, `admin.scope_rejected`, `admin.raw_command`, and the maintenance-schedule edits (`admin.maintenance.updated`, `admin.maintenance.invalid`). Each entry carries `request_id` (correlates the command emit with its result), `session_id_hash` (12-hex-char SHA256 prefix; never the raw session id), `user` (Basic-Auth username), `remote_ip` (post-`X-Forwarded-For` trust walk), and `user_agent`.
- `event == "rate_limit.exceeded"` — the 401-probing throttle. The rate limiter sits **above** the auth gate (so an unauthenticated attacker is throttled before `AdminAuth` ever runs); auditing this event captures who was hitting your admin surface even before they gave up. Carries `remote_ip`, `path`, `retry_after`.

The recommended audit-shipper filter is `event matches "admin.*" OR event == "rate_limit.exceeded"`. A filter that omits `rate_limit.exceeded` loses half the attacker-detection signal.

### Recipe: systemd + journald

Simplest setup if the manager runs as a systemd unit. `StandardOutput=journal` plus journald's own retention controls is enough for a single-host deployment.

```ini
# /etc/systemd/system/cgminer_manager.service (excerpt)
[Service]
ExecStart=/usr/local/bin/bundle exec bin/cgminer_manager run
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cgminer_manager
```

Cap the journal's per-unit storage via a drop-in:

```ini
# /etc/systemd/journald.conf.d/cgminer_manager.conf
[Journal]
SystemMaxUse=2G
MaxFileSec=1week
```

Audit query (last month):

```sh
journalctl -u cgminer_manager --since '1 month ago' -o json \
  | jq 'select(.MESSAGE | fromjson? | (.event | startswith("admin.")) or .event == "rate_limit.exceeded")'
```

### Recipe: Docker / Compose logging driver

Docker's default `json-file` driver writes to `/var/lib/docker/containers/<id>/<id>-json.log` **unbounded** unless capped. Cap it via the compose service's `logging:` block:

```yaml
# docker-compose.yml (excerpt)
services:
  cgminer_manager:
    image: cgminer_manager:latest
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "10"
        # OR: redirect to journald, syslog, fluentd, etc.
```

For audit retention specifically, **prefer a long-lived shipper** (Vector / Fluent-Bit / Promtail) over relying on the json-file driver alone — `docker logs` is host-local and doesn't survive a container removal, which is not a property you want for a compliance-driven audit trail.

### Recipe: Vector / Fluent-Bit sidecar

Forward only audit events to a durable store. Vector example:

```toml
[sources.cgminer_manager]
type = "docker_logs"
include_containers = ["cgminer_manager"]

[transforms.parse]
type = "remap"
inputs = ["cgminer_manager"]
source = '''
  . = parse_json!(.message)
'''

[transforms.audit_only]
type = "filter"
inputs = ["parse"]
condition = '''
  starts_with!(.event, "admin.") || .event == "rate_limit.exceeded"
'''

[sinks.audit_archive]
type = "aws_s3"  # or loki, elasticsearch, file, etc.
inputs = ["audit_only"]
bucket = "my-audit-bucket"
region = "us-east-1"
encoding.codec = "json"
# ... retention / lifecycle policy on the bucket / index ...
```

The same shape works in Fluent-Bit (`filter grep` on the `event` key) and Promtail (`pipeline_stages` with `match`).

### Cross-references

- Full event catalog and standard-key types: [`cgminer_monitor/docs/log_schema.md`](https://github.com/jramos/cgminer_monitor/blob/develop/docs/log_schema.md). Manager's events conform to that contract.
- `request_id` correlation pattern (so an audit query can pivot from `admin.command` to its `admin.result`): same doc's "Standard keys" section.
