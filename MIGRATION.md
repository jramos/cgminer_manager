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

- `POST /manager/run` and `POST /miner/:id/run` arbitrary-command endpoints were removed in 1.1.0 as a security-hardening step. **1.2.0 restores the equivalent functionality behind structured gates** — see the "1.2.0 Admin surface restoration" section below.
  - If you relied on `run` for scripted ad-hoc commands, you can also still use `cgminer_api_client` from IRB:
    ```ruby
    require 'cgminer_api_client'
    miner = CgminerApiClient::Miner.new('10.0.0.5', 4028)
    miner.query(:version)
    ```

## 1.2.0 Admin surface restoration

1.2.0 brings back an Admin tab on the dashboard and per-miner page with fleet operations. Unlike the legacy `/manager/run`, every admin POST is:

- **CSRF-protected** (browser path) with optional **HTTP Basic Auth** bypass for scripts (set `CGMINER_MANAGER_ADMIN_USER` + `CGMINER_MANAGER_ADMIN_PASSWORD`).
- **Scope-restricted** — hardware-tuning verbs (`pgaset`, `ascset`, `pgarestart`, `ascrestart`, `pga{enable,disable}`, `asc{enable,disable}`) refuse `scope=all` to avoid broadcasting clock/voltage settings to heterogeneous hardware.
- **Audit-logged** — `admin.command` / `admin.raw_command` entry events, `admin.result` exit events (threaded by `request_id` UUID), plus `admin.auth_failed` / `admin.scope_rejected` on rejection paths.

Routes added:

- `POST /manager/admin/:command` — typed allowlist (`version`, `stats`, `devs`, `zero`, `save`, `restart`, `quit`).
- `POST /manager/admin/run` — raw cgminer RPC with `command` + `args` + `scope` params.
- `POST /miner/:miner_id/admin/:command` and `POST /miner/:miner_id/admin/run` — per-miner variants.

The typed allowlist is **ergonomic**, not a defensive boundary — anyone with access to `/admin/run` can run any cgminer verb. The defensive boundary is Basic Auth + scope restrictions + audit logging. See README "Security posture" for full details.

## `/api/v1/ping.json`

Unchanged shape: `{timestamp, available_miners, unavailable_miners}`. Data source is now cgminer-direct via `cgminer_api_client` (same as before Rails; explicitly independent of monitor so a monitor outage does not cause the probe to go red).

## Recommended cutover ritual

1. Upgrade `cgminer_monitor` to a release with `/v2/*` endpoints.
2. Verify: `curl http://<monitor>/v2/miners` returns 200 JSON.
3. On the manager host, `bin/cgminer_manager doctor` and confirm every check passes.
4. Stop old manager, start `bin/cgminer_manager run`.

## Rollback

As of 1.1.0 the legacy Rails tree has been removed from HEAD. To roll back to the pre-Sinatra app, check out the `v0-legacy` tag:

```bash
git checkout v0-legacy
bundle install         # uses the old Rails 4.2 Gemfile frozen at that commit
rails server thin      # or `rake server` per the Rails-era README
```

The tag points at the last commit where the Rails app still booted. It is not part of the current HEAD history, so `git log` from master or develop will not show those commits — you must check out the tag explicitly.
