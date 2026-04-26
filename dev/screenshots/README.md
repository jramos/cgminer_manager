# Screenshot regeneration harness

Boots `cgminer_manager` against a scripted fake `cgminer_monitor` so the
dashboard can be screenshotted without physical miners. The scenario
(2× Antminer S3 on `192.168.1.151-152` + 4× Antminer S1 on
`192.168.1.153-156`) reproduces the data shown in the legacy
`public/screenshots/miner-pool.png` from the v0.x Rails era.

## Prerequisites

- Ruby 3.2+ with the repo's Gemfile installed (`bundle install` from the
  repo root).
- Nothing listening on ports **9292** (fake monitor) or **3030** (manager).

## Regenerate

```bash
dev/screenshots/boot.sh
```

This starts two background processes and blocks until both respond:

- Fake `cgminer_monitor` on `127.0.0.1:9292`
- `cgminer_manager` on `127.0.0.1:3030`

Capture the four PNGs (from any browser or Playwright MCP session):

- `http://127.0.0.1:3030/` → `public/screenshots/summary.png` (hide `#miner-pool` via `document.getElementById('miner-pool').style.display = 'none'` before the fullPage shot so only the 6 aggregate graphs render)
- `http://127.0.0.1:3030/` → `public/screenshots/miner-pool.png` (inject `<style>#summary{display:none!important}</style>` before `DOMContentLoaded` so the availability chart draws at full container height)
- `http://127.0.0.1:3030/miner/127.0.0.1%3A40281` → `public/screenshots/miner.png` (Antminer S3 detail; full page)
- `http://127.0.0.1:3030/miner/127.0.0.1%3A40281` → `public/screenshots/miner-admin.png` (click the Admin tab link to expose the per-miner admin commands + Scheduled Restart + Drain section)
- `http://127.0.0.1:3030/` → `public/screenshots/admin.png` (click the Admin tab link after `window.__chartsReady` flips; `initTabs` hides the Summary and Miner Pool panels automatically)

For each, wait until `window.__chartsReady === true` (the flag the graph
partials set after every canvas has rendered), then take a full-page
screenshot at 1280 × 2400 (Chrome will crop the height to actual content).

When finished:

```bash
dev/screenshots/teardown.sh
```

## Files

- `scenario.rb` — the six-miner spec (source of truth). Anchor time is pinned
  to `2026-04-17 09:04:06 UTC`; values use a seeded PRNG so rebuilds are
  byte-identical.
- `fake_monitor.rb` — Sinatra app serving the monitor `/v2/*` API (miners,
  per-miner snapshots, graph data, healthz).
- `miners.yml` — config for the manager's `MINERS_FILE`.
- `boot.sh` / `teardown.sh` — harness lifecycle.
- `.run/` (gitignored) — pidfiles and logs.

To tweak the scenario (different models, miner count, error rates), edit
`scenario.rb` and re-run `boot.sh`. No other files depend on the scenario
shape at runtime.
