# Architecture - end-to-end data flow

This doc walks through what actually happens when this project runs: where the
raw data comes from, how it moves from disk into the warehouse, and how each
Claude Code primitive (`CLAUDE.md`, skills, hooks, subagents, MCP servers) maps
onto a specific point in the flow.

It's the companion to:
- **[README.md](../README.md)** - the architectural pitch (*why* this layout)
- **[AGENT_WORKFLOWS.md](AGENT_WORKFLOWS.md)** - how to drive the agent (*what to type*)
- this doc - *what happens at runtime*

---

## Is it real data or dummy data?

**Real data.** Pulled live from GitHub's public events API
(`https://api.github.com/repos/<owner>/<repo>/events`). No auth required at the
demo's request rate (60 req/hour unauthenticated; 5000/hour if you set
`GITHUB_TOKEN`).

The default repo is `anthropics/anthropic-sdk-python` (set at
`pipelines/ingest_github.py:22`). Override with
`python pipelines/ingest_github.py --repo torvalds/linux` to point at any other
public repo.

There is no fixture file checked into the repo. The CI workflow
(`.github/workflows/ci.yml`) hits the live API on every push too. That's the
"good enough for a demo" trade-off - a production CI would mock the API or use
a committed fixture, but the live round-trip is more honest for teaching
purposes. The cost is that CI is mildly fragile to GitHub API hiccups.

---

## The five-step flow

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub Public Events API (api.github.com)        ← REAL data    │
│   100 most recent public events for the target repo             │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP GET (urllib, no auth required)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ① pipelines/ingest_github.py             Step: ingest           │
│   • Filter response to today's events                           │
│   • Write JSON-lines (1 event per line)                         │
│   • Idempotent: same-day re-run overwrites that partition only  │
│   • On error: writes _FAILED sentinel + JSON log line           │
└──────────────────────────────┬──────────────────────────────────┘
                               │ writes
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ data/raw/github/<YYYY-MM-DD>/data.jsonl      IMMUTABLE raw zone │
│   Today: data/raw/github/<today>/data.jsonl                     │
│   This is where the demo's data physically lives on disk        │
└──────────────────────────────┬──────────────────────────────────┘
                               │ glob read via DuckDB read_json_auto
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ② scripts/load_raw.py                    Step: raw → warehouse  │
│   • Flatten nested JSON (actor.login → actor_login,             │
│     repo.name → repo_name)                                      │
│   • CREATE OR REPLACE TABLE github.events_raw                   │
│   • Idempotent - re-runs rebuild the table from disk            │
└──────────────────────────────┬──────────────────────────────────┘
                               │ writes
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ warehouse.duckdb : github.events_raw                            │
│   Columns: id, type, actor_login, repo_name, created_at,        │
│            public, payload                                      │
└──────────────────────────────┬──────────────────────────────────┘
                               │ {{ source('github', 'events_raw') }}
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ③ dbt build → stg_github__events         Step: stage (typed)   │
│   File:       dbt_project/models/staging/stg_github__events.sql │
│   Materialized: view (per dbt_project.yml)                      │
│   In warehouse: main_staging.stg_github__events                 │
│   • 1:1 with raw, type-cast, renamed                            │
│   • PII conventions applied (none today; would hash here)       │
└──────────────────────────────┬──────────────────────────────────┘
                               │ {{ ref('stg_github__events') }}
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ④ dbt build → events_daily               Step: mart (aggregate)│
│   File:       dbt_project/models/marts/events_daily.sql         │
│   Materialized: table                                           │
│   In warehouse: main_marts.events_daily                         │
│   • Grain: (event_date, repo_name, event_type)                  │
│   • Adds: event_count, unique_actors, dbt_updated_at            │
└──────────────────────────────┬──────────────────────────────────┘
                               │ SELECT from main_marts.events_daily
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ⑤ scripts/data_quality.py                Step: audit            │
│   • Freshness: max(dbt_updated_at) vs SLA (25h)                 │
│   • PK uniqueness on (event_date, repo_name, event_type)        │
│   • Null rates on required columns                              │
│   • PII leak scan (grep marts for unhashed PII column names)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step-by-step detail

### Step ① - Ingest (`pipelines/ingest_github.py`)

Pulls `?per_page=100` from the GitHub events API, filters to events whose
`created_at` starts with today's date, writes them as JSON-lines to
`data/raw/github/<run_date>/data.jsonl`. The script obeys the project's
non-negotiable pipeline conventions (codified in CLAUDE.md and the
`create-pipeline` skill):

- **Date-partitioned writes.** Never overwrite a prior day's partition.
- **`_FAILED` sentinel.** On any exception, write `_FAILED` containing the
  error type+message in the partition directory. The orchestrator and
  `pipeline-debugger` subagent look for these to detect failed runs.
- **Env-var auth.** Optional `GITHUB_TOKEN` bumps the rate limit. Never
  hardcoded.
- **JSON-lines structured logging.** Each event written to stdout is a single
  JSON object the orchestrator parses (`start`, `done`, `error`).

The script is idempotent: re-running with the same `--date` rebuilds that one
partition, leaving every other partition alone. This matters for backfills
(see `backfill-data` skill).

### Step ② - Load (`scripts/load_raw.py`)

Reads the JSONL files via DuckDB's `read_json_auto`, flattens the nested
GitHub structure (`actor.login` → `actor_login`, `repo.name` → `repo_name`),
and materializes `github.events_raw` in `warehouse.duckdb` via
`CREATE OR REPLACE TABLE`.

This is the "raw → warehouse" hop that sits between ingestion and
transformation. It exists as a separate step because:

- Pipelines stay write-only against the immutable raw zone. A bad pipeline
  can't corrupt the warehouse.
- dbt's staging model reads from a real DuckDB source, which keeps it simple
  SQL - no `read_json_auto()` with nested-field unpacking buried in source
  config.

Adding a new source = append a `LOADERS["<source>"]` entry with the right
flatten SQL.

### Step ③ - Stage (`stg_github__events.sql`)

A dbt view that does 1:1 type casting and renaming on `github.events_raw`. No
business logic. The conventions enforced here:

- **Staging models are 1:1 with raw.** No filtering, no joining, no aggregation.
- **Type casts explicit.** `cast(id as bigint)`, `cast(created_at as timestamp)`.
- **PII hashing.** Any column matching `email|phone|ssn|dob|address` must be
  wrapped in `md5(...)`. The `pii-check` hook blocks the write otherwise.

Tests in `schema.yml`: `not_null` on the columns that should always be
populated, `unique` on the PK.

In the warehouse this lives at `main_staging.stg_github__events` -
`main` from DuckDB's default database and `staging` from
`dbt_project.yml`'s `+schema: staging` config.

### Step ④ - Mart (`events_daily.sql`)

A dbt table aggregating staging events to a daily grain. This is the
business-facing layer - what someone querying the warehouse for "events per
repo per day" actually reads.

Grain: `(event_date, repo_name, event_type)`. Adds:
- `event_count` - count of events
- `unique_actors` - count distinct actors
- `dbt_updated_at` - `current_timestamp` at build time (used by
  `data_quality.py` to check freshness)

Tests: `not_null` on every column in the grain plus `event_count`;
`dbt_utils.unique_combination_of_columns` on the composite PK.

In the warehouse: `main_marts.events_daily`.

### Step ⑤ - Audit (`scripts/data_quality.py`)

Read-only checks over the marts:

- **Freshness.** Compute `max(dbt_updated_at)` vs the configured SLA (25 hours
  for `events_daily`). Fail if stale.
- **PK uniqueness.** Distinct PK count == row count.
- **Null rates.** Configured columns have zero nulls.
- **PII leak scan.** Grep `dbt_project/models/marts/*.sql` for unhashed PII
  column names. Catches the case where a mart accidentally pulls in `email`
  from staging without `_hash` suffix.

Output is JSON-lines, parsed by the `data-quality-auditor` subagent. Returns
non-zero exit on any failure so CI and `verify.sh --full` pick it up.

---

## What you can see at each step

You can literally watch the data move through the layers:

```bash
# After step ①
ls data/raw/github/                          # date-partitioned folders
head -1 data/raw/github/<today>/data.jsonl | jq .   # one raw event (nested)

# After step ②
duckdb warehouse.duckdb -c \
  "select count(*), min(created_at), max(created_at) from github.events_raw"

# After step ③
duckdb warehouse.duckdb -c \
  "select * from main_staging.stg_github__events limit 3"

# After step ④
duckdb warehouse.duckdb -c \
  "select * from main_marts.events_daily order by event_count desc"

# Step ⑤
python scripts/data_quality.py
```

---

## How the Claude Code primitives map onto the flow

Each primitive has a specific responsibility at a specific point. This is the
core design that makes the agent setup useful instead of just decorative.

| Primitive | Where it shows up | What it does |
|---|---|---|
| **`CLAUDE.md`** | Read once per session | Encodes the rules every step obeys: raw is immutable (step ① writes to a new partition), PII hashed in staging (step ③), every mart has PK tests (step ④). |
| **Skills** (`.claude/skills/`) | Loaded on demand | `create-pipeline` knows step ①; `add-dbt-model` knows ③/④; `backfill-data` knows the safe way to re-run ①→②→③ for a date range; `debug-pipeline-failure` knows how to triage `_FAILED` sentinels from ①. |
| **Hooks** (`.claude/hooks/`) | Fire on Claude's tool calls | `pre-sql-execute` blocks `DROP TABLE` anywhere; `pii-check` blocks step ③ SQL that selects raw `email` without hashing; `post-write-format` runs `sqlfluff`/`ruff` on writes in steps ①–④. |
| **Subagents** (`.claude/agents/`) | Spawn for verbose work | `pipeline-builder` handles ①–④ in an isolated context when you ask for an end-to-end source; `data-quality-auditor` runs ⑤ on demand; `pipeline-debugger` triages `_FAILED` sentinels; `sql-reviewer` reviews any non-trivial SQL change in ③/④. |
| **MCP servers** (`settings.json`) | Always available to Claude | `warehouse` (read-only DuckDB) lets Claude inspect what's in ②/③/④ without shelling out; `filesystem` (scoped to `./data/`) lets it browse step ①'s output safely. |
| **`scripts/verify.sh`** | Pre-commit, CI, `quality-gate` skill | Confirms steps ①–④ are correctly wired *as code* (lint, parse, build, hook self-tests) before any commit lands. Distinct from data quality (step ⑤), which audits the *data*. |

---

## The one-command version

You don't actually need to run the five scripts by hand. `scripts/run.py` does
it:

```bash
python scripts/run.py
```

Which emits structured log lines:

```
{"event": "orchestrator_start", "run_date": "...", "pipelines": 1, ...}
{"event": "pipeline_start", "source": "github", ...}
{"event": "pipeline_end", "source": "github", "success": true, "exit_code": 0, ...}
{"event": "load_raw_start", ...}
{"event": "load_raw_end", "success": true, ...}
{"event": "dbt_start", ...}
{"event": "dbt_end", "success": true, ...}
{"event": "orchestrator_done", ...}
```

If any step fails, the orchestrator halts and the rest don't run - that's the
demo version of what Airflow/Dagster would do in production.

---

## Where you'd plug in a new source

The flow is shaped so that adding a source (say, Stripe charges) is mostly
parallel work to the existing GitHub pipeline:

1. `pipelines/ingest_stripe.py` - same shape as `ingest_github.py`, writes to
   `data/raw/stripe/<date>/data.jsonl`.
2. Add a `LOADERS["stripe"]` entry in `scripts/load_raw.py` with the right
   flatten SQL.
3. Add a `PIPELINES` entry in `scripts/run.py`.
4. `dbt_project/models/staging/stg_stripe__charges.sql` reading from
   `source('stripe', 'charges_raw')` (plus a source declaration in
   `schema.yml`).
5. Optional mart in `dbt_project/models/marts/`.
6. Configure SLAs/PK in `scripts/data_quality.py:MART_CONFIG` if you added a
   mart.

In a Claude Code session, all of that is one prompt:
`"Add a Stripe charges pipeline end-to-end."` See
[AGENT_WORKFLOWS.md](AGENT_WORKFLOWS.md) for what fires when.

---

## What this architecture deliberately doesn't include

- **A production orchestrator** (Airflow, Dagster, Prefect). `scripts/run.py`
  is the demo stand-in. In a real deployment each step would be a separate
  task with retry policies, alerting, lineage tracking.
- **A streaming path.** Everything here is daily-batch. Real streaming would
  need a Kafka/Kinesis layer between ① and ②, or skip the file landing zone
  entirely.
- **Multi-tenant isolation.** One developer, one local warehouse. A production
  setup would have separate dev/staging/prod databases and per-developer
  schemas.
- **Live observability.** Datadog, Sentry, Monte Carlo - they'd watch the
  *running* warehouse rather than the code. Out of scope for the demo but the
  `data-quality-auditor` subagent + `/schedule` is a partial substitute.

These omissions are intentional: the project is teaching Claude Code patterns,
not how to build a production data platform. The patterns transfer; the
specifics don't.
