"""Ingest GitHub public events for a single repo. Writes to data/raw/github/<run_date>/.

Demonstrates the project's pipeline conventions:
- partition-by-date raw output
- idempotent re-runs (same day = overwrite that partition only)
- JSON-lines structured logging
- _FAILED sentinel on exception
- env-var auth (never hardcoded)
"""
from __future__ import annotations
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import UTC, date, datetime
from pathlib import Path

SOURCE = "github"
RAW_ROOT = Path("data/raw") / SOURCE
DEFAULT_REPO = "anthropics/anthropic-sdk-python"


def log(event: str, **kwargs):
    print(json.dumps({
        "event": event,
        "source": SOURCE,
        "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        **kwargs,
    }), flush=True)


def fetch(run_date: date, repo: str) -> list[dict]:
    """Fetch public events for the given repo. Returns a list of event dicts."""
    url = f"https://api.github.com/repos/{repo}/events?per_page=100"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})

    # Optional auth — higher rate limits when set
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, timeout=30) as resp:
        events = json.loads(resp.read())

    # Filter to the target date so the partition is actually scoped
    target = run_date.isoformat()
    return [e for e in events if e.get("created_at", "").startswith(target)]


def main(run_date: date | None = None, repo: str = DEFAULT_REPO) -> int:
    run_date = run_date or date.today()
    out_dir = RAW_ROOT / run_date.isoformat()
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "data.jsonl"

    try:
        log("start", run_date=run_date.isoformat(), repo=repo)
        records = fetch(run_date, repo)
        with out_file.open("w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        log("done", rows=len(records), path=str(out_file))
        return 0
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
        (out_dir / "_FAILED").write_text(f"{type(e).__name__}: {e}")
        log("error", error_type=type(e).__name__, error=str(e))
        return 1
    except Exception as e:  # noqa: BLE001 — last-resort catch, we want the sentinel written
        (out_dir / "_FAILED").write_text(f"{type(e).__name__}: {e}")
        log("error", error_type=type(e).__name__, error=str(e))
        return 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--date", type=lambda s: date.fromisoformat(s), default=None,
                   help="Partition date (YYYY-MM-DD). Defaults to today.")
    p.add_argument("--repo", default=DEFAULT_REPO, help="GitHub repo owner/name")
    args = p.parse_args()
    sys.exit(main(args.date, args.repo))
