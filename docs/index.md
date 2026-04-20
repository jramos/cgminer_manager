# Knowledge Base Index — `cgminer_manager`

**This file is the entry point for AI assistants working on `cgminer_manager`.** It summarizes every other document in `docs/` so an assistant can pull in only the file(s) relevant to a given question. When no single file is an obvious fit, read `AGENTS.md` (consolidated, at repo root) or skim `codebase_info.md` first.

## How to use this index

1. **Identify the question category** from the table below (Architecture? HTTP API? Admin surface? Operational concern?).
2. **Read the mapped file.** Each mapping includes a one-line "use this when" hook plus a brief summary below.
3. **Cross-reference** via the explicit links between documents — they're maintained.
4. **Fall back** to reading the code. All docs are derived from `lib/`, `bin/`, `views/`, and `spec/`; if a doc and the code disagree, the code is truth and the doc is stale (please flag it).

## Question → file map

| If the question is about... | Start here |
|---|---|
| "what is this project?" / stack / file tree / module graph | [`codebase_info.md`](codebase_info.md) |
| two-upstream model (monitor HTTP + cgminer TCP) / signal dance / admin request lifecycle / CSRF ↔ Basic Auth interaction / audit logging | [`architecture.md`](architecture.md) |
| what each class/module does / where a piece of behavior lives | [`components.md`](components.md) |
| HTTP routes / CLI exit codes / env-var table / `miners.yml` schema / structured log schema | [`interfaces.md`](interfaces.md) |
| `Data.define` value objects / `Config` invariants / `SnapshotAdapter` shape translation / error hierarchy | [`data_models.md`](data_models.md) |
| startup / dashboard render / pool ops / admin flow / graceful shutdown / test harness / release | [`workflows.md`](workflows.md) |
| runtime + dev deps / Ruby version floors / CI matrix / why no Rails/Mongoid | [`dependencies.md`](dependencies.md) |
| known doc/code drift / dead or unwired code paths / cleanup recommendations | [`review_notes.md`](review_notes.md) |

## Document summaries

### [`codebase_info.md`](codebase_info.md)
**Purpose:** The one-pager. What cgminer_manager is (Sinatra web UI on top of cgminer_monitor + cgminer_api_client), what Ruby/Mongo versions it requires (Ruby 3.2+, no Mongo), full file tree, and a high-level module graph showing the two upstream dependencies. **Start here if you've never seen the project.**

### [`architecture.md`](architecture.md)
**Purpose:** Why the code is shaped the way it is. Covers: the single-process-two-signal-handler-installs Puma model, the signal-handler reinstall dance around Puma's `setup_signals`, the dashboard request lifecycle (parallel fan-out to monitor tiles), the admin request lifecycle (AdminAuth → ConditionalAuthenticityToken → command validation → scope check → audit-logged fan-out), the pool-management write-verify-save pattern, graceful shutdown, and the ergonomic-vs-defensive distinction for the admin surface. **Read this before making non-trivial structural changes.**

### [`components.md`](components.md)
**Purpose:** Catalog of every file in `lib/cgminer_manager/` with responsibilities, key public methods, and call-out gotchas. Includes the CLI subcommand table, the `AdminAuth` + `ConditionalAuthenticityToken` middleware pair, `SnapshotAdapter`'s shape-translation job, the three-state `PoolManager::MinerEntry` semantics, and the monkey-patched `CgminerApiClient::Miner#to_s` at the top of `http_app.rb`. **Read this to find where a specific piece of behavior lives.**

### [`interfaces.md`](interfaces.md)
**Purpose:** Exhaustive contract reference. All 14 HTTP routes with method/path/purpose/response type. CLI subcommands and exit codes (0/1/2/64). Env-var config table (14 vars). `miners.yml` schema. CSRF + Basic Auth interaction rules. Scope restrictions list (which admin verbs refuse `scope=all`). Graph-data response shape per metric. Structured log event catalog. **Read this for API/CLI/config questions.**

### [`data_models.md`](data_models.md)
**Purpose:** Runtime data shapes. `Config`, `ViewMiner`/`ViewMinerPool`, `FleetQueryResult`/`FleetWriteResult` + their entry types, `PoolManager::MinerEntry` (with three-state command_status), monitor's `/v2/*` JSON envelope. The `SnapshotAdapter` shape translation (input vs output example). Error class hierarchy with raise-site table. **Read this for "what's in this object" questions.**

### [`workflows.md`](workflows.md)
**Purpose:** Sequence diagrams + step-by-step flows. Startup (signal-handler dance), dashboard render (snapshot fan-out), pool management (write + verify + save), admin run (AdminAuth + CSRF + command validation + scope check + commander fan-out), graceful shutdown. Plus dev workflows (running tests, regenerating screenshots, refreshing monitor fixtures) and release process. **Read this to understand how code paths compose over time.**

### [`dependencies.md`](dependencies.md)
**Purpose:** Runtime deps (cgminer_api_client, Sinatra, sinatra-contrib, Puma, HAML, http, rack-protection — no MongoDB, no Rails), dev deps (rspec, webmock, rack-test, rubocop, simplecov, parallel pinned <2.0). Ruby version rationale (3.2+ for `Data.define` and endless methods). CI matrix (lint + test matrix + integration, plus nightly for 4.0/head). Why the dep set is small (the 1.0 rewrite deleted Rails/Mongoid/Sprockets). **Read this for "can I add gem X?" or "why is parallel pinned?" questions.**

### [`review_notes.md`](review_notes.md)
**Purpose:** Self-audit. Cross-file consistency check (passed). Remaining gaps in the code (exit code 2 vs 78 convention, no OpenAPI parity check, per-request thread-pool spawn, no `brakeman`, `session_id_hash` truncation rationale not in-code, `raw!`'s intentional comma-split pass-through). Gaps in these docs themselves. Recommendations with effort/value triage. **Read this before trusting a confident-sounding claim elsewhere in these docs.**

## Example queries and where to go

| Query | Primary file(s) |
|---|---|
| "How do I add a new HTTP route?" | `components.md` (HttpApp) + `interfaces.md` (current route list) + root `AGENTS.md` for the exact step list |
| "How do I add a new graph metric?" | `architecture.md` (read path) + `interfaces.md` (graph response shape) + `components.md` (HttpApp `GRAPH_METRIC_PROJECTIONS`) |
| "What happens when monitor is down but some cgminers are up?" | `architecture.md` (dashboard read path) + `workflows.md` (dashboard render) |
| "Why can I curl `/manager/admin/run` when I send Basic Auth but not when I just send a cookie?" | `architecture.md` (CSRF ↔ Basic Auth interaction) + `components.md` (AdminAuth + ConditionalAuthenticityToken) |
| "What error codes does the CLI use?" | `interfaces.md` (CLI section) + `review_notes.md` (gap #2 on 2 vs 78) |
| "Where does `@miner_data` come from?" | `architecture.md` (dashboard flow) + `components.md` (SnapshotAdapter) + `data_models.md` (in-request transient state) |
| "Can pool management survive a transient cgminer error?" | `components.md` (PoolManager three-state) + `data_models.md` (MinerEntry) + `workflows.md` (pool flow) |
| "What version of Ruby can I use?" | `dependencies.md` |
| "What's logged when an admin command runs?" | `interfaces.md` (log event catalog) + `architecture.md` (admin audit log schema) |

## Maintenance note

These docs were generated by analyzing 1.2.0 source. They reflect the state at that release. When the code changes substantially:

- Prefer updating the specific file that contains the affected claim (smaller diffs, clearer history).
- Update `review_notes.md` if you find a new inconsistency or gap.
- Re-run the codebase-summary skill in `update_mode=true` if the surface area has shifted enough to warrant a re-analysis.

If you're an AI assistant and you find a doc that contradicts the current code, **trust the code** and flag the discrepancy to the maintainer rather than silently fixing the doc.
