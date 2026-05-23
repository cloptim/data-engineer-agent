"""Demo orchestrator. In production this is Airflow/Dagster/Prefect — here it's a script
that runs all pipelines and then dbt, with structured logging.

The point of including this is to show how the pipeline scripts plug into orchestration:
each pipeline returns an exit code, writes a _FAILED sentinel on failure, and the orchestrator
makes a go/no-go decision on whether to proceed to transforms.
"""
from __future__ import annotations
import json
import subprocess
import sys
from datetime import UTC, date, datetime

# Each pipeline declares its source slug and the script to run.
# Adding a new source = one line here + one file in pipelines/.
PIPELINES = [
    {"source": "github", "script": "pipelines/ingest_github.py"},
    # {"source": "stripe", "script": "pipelines/ingest_stripe.py"},
    # ... add more
]


def log(event: str, **kwargs):
    print(json.dumps({
        "event": event,
        "orchestrator": True,
        "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        **kwargs,
    }), flush=True)


def run_pipeline(pipeline: dict, run_date: date) -> bool:
    log("pipeline_start", source=pipeline["source"])
    result = subprocess.run(
        [sys.executable, pipeline["script"], "--date", run_date.isoformat()],
        capture_output=True,
        text=True,
    )
    success = result.returncode == 0
    log("pipeline_end", source=pipeline["source"], success=success, exit_code=result.returncode)
    if not success:
        log("pipeline_stderr", source=pipeline["source"], stderr=result.stderr[:1000])
    return success


def run_load_raw() -> bool:
    """Materialize JSONL partitions into DuckDB <source>.events_raw tables."""
    log("load_raw_start")
    result = subprocess.run(
        [sys.executable, "scripts/load_raw.py"], capture_output=True, text=True,
    )
    success = result.returncode == 0
    log("load_raw_end", success=success, exit_code=result.returncode)
    if not success:
        log("load_raw_stderr", stderr=result.stderr[:1000])
    return success


def run_dbt() -> bool:
    log("dbt_start")
    result = subprocess.run(
        ["dbt", "build"], cwd="dbt_project", capture_output=True, text=True,
    )
    success = result.returncode == 0
    log("dbt_end", success=success)
    return success


def main() -> int:
    run_date = date.today()
    log("orchestrator_start", run_date=run_date.isoformat(), pipelines=len(PIPELINES))

    results = {p["source"]: run_pipeline(p, run_date) for p in PIPELINES}
    failed = [s for s, ok in results.items() if not ok]

    if failed:
        log("orchestrator_halt", reason="pipeline_failures", failed=failed)
        return 1

    if not run_load_raw():
        log("orchestrator_halt", reason="load_raw_failure")
        return 2

    if not run_dbt():
        log("orchestrator_halt", reason="dbt_failure")
        return 3

    log("orchestrator_done", run_date=run_date.isoformat())
    return 0


if __name__ == "__main__":
    sys.exit(main())
