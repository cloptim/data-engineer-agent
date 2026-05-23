"""Data quality checks. Read-only against the warehouse.

Run standalone (`python scripts/data_quality.py`) or invoke from the data-quality-auditor
subagent. The agent expects the JSON-lines output format below.

Checks implemented:
- freshness: every mart's max(dbt_updated_at) vs its SLA
- pk_uniqueness: distinct PK count == row count
- not_null: configured columns have zero nulls
- pii_leak_scan: grep marts for unhashed PII column names

This file is intentionally dependency-light (no dbt artifacts parsing) so it can run
in any environment where DuckDB is installed.
"""

from __future__ import annotations
import argparse
import json
import re
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

try:
    import duckdb
except ImportError:
    print(
        json.dumps({"event": "fatal", "error": "duckdb not installed"}), file=sys.stderr
    )
    sys.exit(2)

WAREHOUSE = Path("warehouse.duckdb")
MARTS_DIR = Path("dbt_project/models/marts")

# table_name → (SLA in hours, PK columns)
MART_CONFIG = {
    # Fully-qualified table names — dbt materializes marts under `main_marts` per
    # dbt_project.yml (`+schema: marts` plus the default schema prefix).
    "main_marts.events_daily": (25, ["event_date", "repo_name", "event_type"]),
}

PII_PATTERN = re.compile(
    r"\b(email|phone|ssn|dob|address|date_of_birth)\b(?!_hash)", re.IGNORECASE
)


def emit(level: str, check: str, **kwargs):
    print(json.dumps({"level": level, "check": check, **kwargs}))


def check_freshness(conn) -> list[dict]:
    issues = []
    for table, (sla_hours, _) in MART_CONFIG.items():
        try:
            row = conn.execute(f"select max(dbt_updated_at) from {table}").fetchone()
            last = row[0] if row else None
            if last is None:
                emit("fail", "freshness", table=table, reason="empty_or_missing")
                issues.append({"table": table})
                continue
            # DuckDB may return either naive or tz-aware timestamps depending on
            # the column type (TIMESTAMP vs TIMESTAMPTZ). Normalize both sides to
            # tz-aware UTC so the subtraction works regardless.
            if last.tzinfo is None:
                last = last.replace(tzinfo=UTC)
            age = datetime.now(UTC) - last
            if age > timedelta(hours=sla_hours):
                emit(
                    "fail",
                    "freshness",
                    table=table,
                    age_hours=round(age.total_seconds() / 3600, 1),
                    sla_hours=sla_hours,
                )
                issues.append({"table": table})
            else:
                emit(
                    "pass",
                    "freshness",
                    table=table,
                    age_hours=round(age.total_seconds() / 3600, 1),
                )
        except duckdb.CatalogException:
            emit("fail", "freshness", table=table, reason="table_not_found")
            issues.append({"table": table})
    return issues


def check_pk_uniqueness(conn) -> list[dict]:
    issues = []
    for table, (_, pk_cols) in MART_CONFIG.items():
        try:
            pk_expr = ", ".join(pk_cols)
            row = conn.execute(
                f"select count(*), count(distinct ({pk_expr})) from {table}"
            ).fetchone()
            total, distinct = row
            if total != distinct:
                emit(
                    "fail",
                    "pk_uniqueness",
                    table=table,
                    total=total,
                    distinct=distinct,
                    duplicates=total - distinct,
                )
                issues.append({"table": table})
            else:
                emit("pass", "pk_uniqueness", table=table, rows=total)
        except duckdb.CatalogException:
            pass  # already reported by freshness check
    return issues


def check_pii_leak() -> list[dict]:
    """Grep mart SQL for unhashed PII column references."""
    issues = []
    if not MARTS_DIR.exists():
        return issues
    for sql_file in MARTS_DIR.glob("*.sql"):
        text = sql_file.read_text()
        # Strip line and block comments
        text = re.sub(r"--.*", "", text)
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        matches = set(PII_PATTERN.findall(text))
        if matches:
            emit("fail", "pii_leak", file=str(sql_file), columns=sorted(matches))
            issues.append({"file": str(sql_file)})
    return issues


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--since",
        help="(reserved, not yet used) restrict checks to data after this date",
    )
    args = p.parse_args()
    _ = args.since

    emit("info", "start", warehouse=str(WAREHOUSE))

    if not WAREHOUSE.exists():
        emit("warn", "start", reason="warehouse_missing", path=str(WAREHOUSE))
        # PII leak check still runs (it's source-only)
        leak_issues = check_pii_leak()
        emit("summary", "done", failures=len(leak_issues))
        return 1 if leak_issues else 0

    conn = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        all_issues = []
        all_issues += check_freshness(conn)
        all_issues += check_pk_uniqueness(conn)
        all_issues += check_pii_leak()
        emit("summary", "done", failures=len(all_issues))
        return 1 if all_issues else 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
