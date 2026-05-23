# DataOps Agent — Project Memory

> This file is read by Claude Code at the start of every session.
> It encodes the "house rules" so Claude behaves like a senior data engineer
> on *this* project, not a generic assistant.

## What this project is

A small, realistic analytics stack:

- **Ingestion** (`pipelines/`) — Python scripts that pull from APIs / drop files into `data/raw/`.
- **Warehouse** — DuckDB file at `warehouse.duckdb` (Postgres-compatible enough for the demo).
- **Transforms** (`dbt_project/`) — dbt-style staging → marts models.
- **Orchestration** — plain `scripts/run.py` for the demo (in production this would be Airflow/Dagster).
- **Quality** — dbt tests + a custom `scripts/data_quality.py` checker.

## Hard rules (Claude must follow)

1. **Never run destructive SQL without a typed confirmation.**
   `DROP`, `TRUNCATE`, `DELETE` without `WHERE`, and `ALTER ... DROP COLUMN` are blocked by the
   `pre-sql-execute` hook. Do not try to bypass it. If the user really needs it, tell them to
   run the command manually after backup.
2. **Raw data is immutable.** Files in `data/raw/` are never edited or overwritten. New ingest
   runs write to `data/raw/<source>/<YYYY-MM-DD>/`.
3. **All warehouse writes go through dbt or a pipeline script.** No ad-hoc `INSERT` from notebooks.
4. **Schema changes require a migration file** in `dbt_project/migrations/` with a timestamp prefix.
5. **PII columns** (anything matching `email`, `phone`, `ssn`, `dob`, `address`) must be hashed
   in staging models. The `pii-check` hook scans new SQL files for this.

## Tech conventions

- **Python**: 3.11+. Use `polars` for DataFrames (not pandas) unless interop forces it.
- **SQL style**: lowercase keywords, trailing commas, CTEs over subqueries, one column per line
  in `SELECT`. Auto-formatted by `sqlfluff` via the post-write hook.
- **Naming**:
  - Staging models: `stg_<source>__<entity>.sql`
  - Marts: `<domain>_<grain>.sql` (e.g. `orders_daily.sql`)
  - Pipeline scripts: `ingest_<source>.py`
- **Tests**: every mart model needs at least `not_null` and `unique` tests on its primary key.
- **Idempotency**: pipelines must be safe to re-run for the same date partition.

## Where things live

```
pipelines/        → ingestion scripts (one per source)
dbt_project/      → transformations
  models/staging/ → 1:1 with source tables, light typing + PII hashing
  models/marts/   → business-facing aggregates
  tests/          → singular tests
scripts/          → orchestration & ops utilities
data/raw/         → immutable landing zone (partitioned by date)
data/processed/   → intermediate files (safe to delete)
.claude/          → agent configuration (skills, subagents, hooks)
```

## How to delegate (when to spawn a subagent)

- New pipeline for a new source → use the `pipeline-builder` subagent.
- SQL/dbt model review before merge → use the `sql-reviewer` subagent.
- A pipeline failed and we need a root cause → use the `pipeline-debugger` subagent.
- Weekly data quality audit → use the `data-quality-auditor` subagent.

The main session should stay focused on planning and user dialogue. Heavy file
exploration, log digging, and multi-file refactors belong in subagents so the main
context window doesn't get polluted with stack traces and SQL dumps.

## Skills available

Loaded on demand — do not preload. Just know they exist:

- `create-pipeline` — scaffolds a new ingestion script with the project's idempotency pattern.
- `add-dbt-model` — adds a staging or mart model with conventional tests.
- `debug-pipeline-failure` — structured triage steps for a failed run.
- `backfill-data` — safe procedure for backfilling a date range.

## What "done" means here

A change is done when:

- [ ] Code passes `sqlfluff` and `ruff`
- [ ] `dbt build` runs clean (tests included)
- [ ] `scripts/data_quality.py` reports no new violations
- [ ] `CHANGELOG.md` has an entry
- [ ] PII rules are respected (the hook will block you otherwise)
