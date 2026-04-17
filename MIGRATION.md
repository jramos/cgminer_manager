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

1. Upgrade `cgminer_monitor` to a release with `/v2/*` endpoints.
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
