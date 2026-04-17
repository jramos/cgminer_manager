# cgminer_manager

Web UI for operating cgminer rigs. Displays data fetched from [`cgminer_monitor`](https://github.com/jramos/cgminer_monitor) and issues pool-management commands to miners via [`cgminer_api_client`](https://github.com/jramos/cgminer_api_client).

## Requirements

- Ruby 3.2+ (4.0.2 recommended; see `.ruby-version`)
- A running `cgminer_monitor` instance exposing `/v2/*`
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

## HTTP surface

- `GET /` — dashboard (miner rows + 6 summary graphs).
- `GET /miner/:miner_id` — per-miner page (4 tabs: Miner/Devs/Pools/Stats). `:miner_id` is URL-encoded `host:port`.
- `GET /graph_data/:metric` — aggregate graph data across all miners. Returns a JSON array of rows.
- `GET /miner/:miner_id/graph_data/:metric` — per-miner graph data, same shape.
- `POST /manager/manage_pools`, `POST /miner/:miner_id/manage_pools` — pool management commands (CSRF-protected).
- `GET /api/v1/ping.json` — legacy probe, returns `{timestamp, available_miners, unavailable_miners}` computed directly from cgminers.
- `GET /healthz` — service health (manager + monitor reachability).

Supported graph metrics: `hashrate` (7 columns), `temperature` (4 columns), `availability` (2-3 columns).

## Development

```bash
bundle install
bundle exec rake  # rubocop + rspec
```

## Security posture

Default bind is `127.0.0.1`. The service is designed for secure local networks; to expose it beyond localhost, put it behind a reverse proxy that provides authentication.

## License

MIT. See LICENSE.txt.
