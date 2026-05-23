# Changelog

All notable changes to this project are recorded here. Required by CLAUDE.md.

## 2026-05-23

- Initial scaffold: ingestion (GitHub), staging + mart dbt models, orchestrator, data quality
  checker, hooks (pre-sql-execute, pii-check, post-write-format), subagents (sql-reviewer,
  data-quality-auditor, pipeline-debugger, pipeline-builder), skills (create-pipeline,
  add-dbt-model, debug-pipeline-failure, backfill-data).
- Hook test suite added (`scripts/test-hooks.sh`) - 12/12 passing.
- Setup gaps closed so a fresh clone can run end-to-end (`dbt build` now 12/12 pass):
  - Added `dbt_project/profiles.yml` (DuckDB connection, points at `../warehouse.duckdb`)
    so no `~/.dbt` setup is required.
  - Added `dbt_project/packages.yml` declaring `dbt-labs/dbt_utils` (required by the marts
    `unique_combination_of_columns` test).
  - Added `scripts/load_raw.py` - the missing "raw → warehouse" hop. Reads JSONL partitions
    under `data/raw/<source>/`, flattens nested fields (e.g. `actor.login` → `actor_login`),
    and writes `<source>.events_raw` tables via idempotent `CREATE OR REPLACE TABLE`.
  - Orchestrator (`scripts/run.py`) now calls the loader between pipelines and dbt.
  - README updated: numbered steps now include `dbt deps` and `load_raw.py`; layout diagram
    mentions `load_raw.py`; added a fallback block showing how to create `profiles.yml`
    by hand if it isn't in the repo.
- Deprecation cleanup:
  - `models/marts/schema.yml`: `dbt_utils.unique_combination_of_columns` now nests
    `combination_of_columns:` under `arguments:` (dbt 1.11 requirement).
  - Replaced `datetime.utcnow()` with `datetime.now(UTC)` across `pipelines/ingest_github.py`,
    `scripts/load_raw.py`, `scripts/run.py`, and `scripts/data_quality.py`. Log timestamp
    format (`...Z`) preserved.
- Agent-usage documentation:
  - Added `docs/AGENT_WORKFLOWS.md` - the one-prompt workflow guide. Cheat-sheet
    table of recipes, worked example of "add a new source end-to-end" with what
    fires when, and the design rationale for why skills + isolated subagents +
    deterministic hooks beat a monolithic system prompt on token efficiency.
  - Added `.claude/skills/agent-workflows/SKILL.md` - a tiny meta-skill that
    routes "how do I use this project?" questions to the doc, so Claude
    surfaces the guide automatically without a human having to find it.
  - README: new "Driving the agent" section between "Trying it out" and
    "Design notes" with the cheat-sheet and a pointer to the full doc.
- Architecture documentation:
  - Added `docs/ARCHITECTURE.md` - end-to-end runtime walkthrough. Answers "is
    this real or dummy data?" (real, live GitHub events API), shows the five-step
    flow (ingest → land → load → stage → mart → audit) with an ASCII diagram,
    per-step detail with file references, and a table mapping each Claude Code
    primitive (CLAUDE.md, skills, hooks, subagents, MCP servers, verify.sh) onto
    where it fires in the flow.
  - Added `.claude/skills/architecture-overview/SKILL.md` - meta-skill that
    routes "how does this work?" / "where does the data come from?" /
    "explain the architecture" questions to the doc.
  - README: added a second pointer in the "Driving the agent" section linking
    to ARCHITECTURE.md.
- Quality gate (agent-independent commit safety net):
  - Added `scripts/verify.sh` - single-command quality gate (ruff, sqlfluff, dbt
    parse, hook self-tests; `--full` adds dbt build + data quality). Single
    source of truth - pre-commit, CI, and the new `quality-gate` skill all call
    this so they can't drift apart.
  - Added `.pre-commit-config.yaml` - local git pre-commit gate that delegates
    to `scripts/verify.sh`. Catches commits from anyone, not just Claude. Install
    with `pre-commit install` after cloning.
  - Added `.github/workflows/ci.yml` - server-side CI gate. Installs deps,
    ingests sample data, loads, runs `dbt deps`, then `scripts/verify.sh --full`.
    Uploads dbt artifacts on failure.
  - Added `.claude/skills/quality-gate/SKILL.md` - agent-driven quality gate.
    Triggers on "verify my changes" / "is this ready to commit". Runs
    `verify.sh`, classifies failures (lint vs parse vs build vs DQ), proposes
    fixes. Explicitly tells Claude not to bypass the gate or suppress findings.
  - Added `.sqlfluff` - SQL lint config aligned with CLAUDE.md style (trailing
    commas allowed, lowercase keywords, 100-char lines).
  - Added `requirements.txt` - pinned runtime + dev deps so CI is reproducible.
  - Fixed two pre-existing bugs surfaced by `verify.sh --full`:
    - `scripts/data_quality.py`: `MART_CONFIG` referenced `events_daily` without
      the `main_marts.` schema prefix, so the freshness check couldn't find the
      table. Qualified.
    - `scripts/data_quality.py`: freshness subtraction assumed naive timestamps,
      but DuckDB's `current_timestamp` returns tz-aware values. Now normalizes
      both sides to UTC before subtracting.
  - Reformatted existing dbt SQL (`stg_github__events.sql`, `events_daily.sql`)
    with `sqlfluff fix` so they pass the new lint config. Functional content
    unchanged - only the gratuitous column alignment was collapsed.
