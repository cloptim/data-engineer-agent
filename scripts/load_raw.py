"""Load raw JSONL partitions from data/raw/<source>/ into the DuckDB warehouse.

This is the "raw → warehouse" hop that sits between ingestion (pipelines/) and
transformation (dbt). It is deliberately tiny:

  pipelines/ingest_*.py  →  data/raw/<source>/<date>/data.jsonl
  scripts/load_raw.py    →  warehouse.duckdb : <source>.events_raw         ← here
  dbt build              →  staging + marts

Why a separate step (not done by the pipeline, not done by dbt):
- Pipelines stay write-only against the immutable raw zone. They never touch the
  warehouse, so a bad pipeline run can't corrupt the warehouse.
- dbt reads from a real DuckDB source. Keeps the staging model simple SQL
  instead of a read_json_auto() with nested-field unpacking buried in source config.

Idempotency: uses CREATE OR REPLACE TABLE, so re-running for the same partitions
is safe — the table is rebuilt from whatever JSONL files currently exist on disk.

Adding a new source: append an entry to LOADERS below.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import duckdb

WAREHOUSE = Path(__file__).resolve().parents[1] / "warehouse.duckdb"
RAW_ROOT = Path(__file__).resolve().parents[1] / "data" / "raw"


def log(event: str, **kwargs):
    print(json.dumps({
        "event": event,
        "loader": True,
        "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        **kwargs,
    }), flush=True)


# Per-source flatten SQL. The SELECT shape must match what the corresponding
# staging model (stg_<source>__events.sql) expects.
LOADERS: dict[str, str] = {
    "github": """
        CREATE OR REPLACE TABLE github.events_raw AS
        SELECT
            id,
            type,
            actor.login                       AS actor_login,
            repo.name                         AS repo_name,
            created_at,
            public,
            CAST(payload AS VARCHAR)          AS payload
        FROM read_json_auto(
            '{glob}',
            format = 'newline_delimited',
            ignore_errors = true
        )
    """,
}


def load_source(con: duckdb.DuckDBPyConnection, source: str) -> int:
    """Load all partitions for one source into <source>.events_raw. Returns row count."""
    if source not in LOADERS:
        raise KeyError(f"No loader defined for source '{source}'. Known: {list(LOADERS)}")

    glob = str(RAW_ROOT / source / "*" / "data.jsonl")
    matches = list((RAW_ROOT / source).glob("*/data.jsonl"))
    if not matches:
        log("skip_empty", source=source, reason="no partitions found", glob=glob)
        return 0

    con.execute(f"CREATE SCHEMA IF NOT EXISTS {source}")
    con.execute(LOADERS[source].format(glob=glob))
    rows = con.execute(f"SELECT count(*) FROM {source}.events_raw").fetchone()[0]
    log("loaded", source=source, table=f"{source}.events_raw", rows=rows, partitions=len(matches))
    return rows


def main(sources: list[str] | None) -> int:
    sources = sources or list(LOADERS)
    log("start", warehouse=str(WAREHOUSE), sources=sources)

    con = duckdb.connect(str(WAREHOUSE))
    try:
        for s in sources:
            load_source(con, s)
    finally:
        con.close()

    log("done")
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument(
        "--source",
        action="append",
        help="Load just this source (repeatable). Default: load all known sources.",
    )
    args = p.parse_args()
    sys.exit(main(args.source))
