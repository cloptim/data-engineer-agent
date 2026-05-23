---
name: create-pipeline
description: Use this skill when the user wants to add a new ingestion pipeline for a new data source (API, file drop, database, webhook). Triggers include "add a pipeline for X", "ingest data from Y", "set up a new source", "pull data from <API/service>". Produces an idempotent Python script in pipelines/ following the project's partition-by-date pattern.
---

# Create a new ingestion pipeline

## When to invoke

The user wants to add a *new source* to the warehouse. Not modifying an existing one - that's a
straight edit. This is "we just signed up for the Stripe API, get the data in."

## Procedure

1. **Clarify in one question, max.** You need:
   - source name (short slug, e.g. `stripe`, `salesforce`, `shopify`)
   - extraction mode: `full` (re-pull everything every run) or `incremental` (by `updated_at` cursor)
   - auth: env var name for the API key, or path to a credentials file
   If any of these are obvious from context, don't ask - assume and state the assumption.

2. **Scaffold the script** at `pipelines/ingest_<source>.py` using the template below.
   The template is non-negotiable on three points:
   - Writes to `data/raw/<source>/<run_date>/` - never overwrites a previous day.
   - Wraps the whole thing in a `try/except` that writes a `_FAILED` sentinel file on error.
   - Logs to stdout in JSON lines so the orchestrator can parse it.

3. **Register it** in `scripts/run.py` (the demo orchestrator). Add the source to the
   `PIPELINES` list with a cron-style schedule.

4. **Create a corresponding staging model** at `dbt_project/models/staging/stg_<source>__<entity>.sql`.
   Even a stub - it signals the contract. Use the `add-dbt-model` skill for this step.

5. **Do not** add credentials to the repo. Reference the env var name in a comment in
   `.env.example` and tell the user to set it.

## Script template

```python
"""Ingest <SOURCE>. Writes to data/raw/<source>/<run_date>/."""
from __future__ import annotations
import json, os, sys
from datetime import date
from pathlib import Path

SOURCE = "<source>"
RAW_ROOT = Path("data/raw") / SOURCE

def log(event: str, **kwargs):
    print(json.dumps({"event": event, "source": SOURCE, **kwargs}), flush=True)

def fetch(run_date: date) -> list[dict]:
    # TODO: implement extraction. Use the cursor pattern for incremental.
    raise NotImplementedError

def main(run_date: date | None = None) -> int:
    run_date = run_date or date.today()
    out_dir = RAW_ROOT / run_date.isoformat()
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        log("start", run_date=run_date.isoformat())
        records = fetch(run_date)
        out_file = out_dir / "data.jsonl"
        with out_file.open("w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        log("done", rows=len(records), path=str(out_file))
        return 0
    except Exception as e:
        (out_dir / "_FAILED").write_text(str(e))
        log("error", error=str(e))
        return 1

if __name__ == "__main__":
    sys.exit(main())
```

## Common mistakes to avoid

- Writing to a single `data/raw/<source>.jsonl` file. Breaks idempotency and backfills.
- Putting credentials in the script. They go in env vars.
- Forgetting the `_FAILED` sentinel. The orchestrator relies on it to know a partition is bad.
- Skipping the staging model. Downstream consumers won't know the table exists.
