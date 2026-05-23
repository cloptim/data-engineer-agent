---
name: debug-pipeline-failure
description: Use this skill when a pipeline run failed and the user wants to find out why. Triggers include "the pipeline failed", "X pipeline is broken", "yesterday's run errored", "_FAILED file appeared", "data didn't land". Provides structured triage steps and recovery actions. Strongly consider delegating to the pipeline-debugger subagent for the actual log digging — this skill is the runbook the subagent (or you) follows.
---

# Debug a failed pipeline run

This is a runbook. Follow the steps in order. **Don't guess. Each step has a clear output that tells you whether to continue or stop.**

## Step 1 — Locate the failure

```bash
find data/raw -name "_FAILED" -newer /tmp/.last-checked 2>/dev/null
```

The `_FAILED` sentinel is written by every pipeline on exception (see the `create-pipeline` skill).
Each one contains the exception message. Read it.

If there's no `_FAILED` file but the user says "the pipeline failed", check stdout logs:
```bash
ls -lt logs/ | head
```

## Step 2 — Classify the failure

Read the exception. It falls into one of four buckets:

| Bucket | Signal | First action |
|---|---|---|
| **Auth** | 401, 403, "invalid credentials", "token expired" | Check env vars, do NOT retry blindly |
| **Schema drift** | KeyError, "column not found", type cast errors | Diff against last successful raw file |
| **Upstream outage** | 5xx, timeouts, connection refused | Check source status page, then retry |
| **Our bug** | TypeError, AttributeError, IndexError in our code | Fix code, then backfill the partition |

If you can't classify it, that's the answer: tell the user and ask for the full traceback before guessing.

## Step 3 — Schema drift specifically (most common in practice)

```bash
# Compare today's partition to the last good one
diff <(jq -r 'keys[]' data/raw/<source>/<bad_date>/data.jsonl | sort -u) \
     <(jq -r 'keys[]' data/raw/<source>/<good_date>/data.jsonl | sort -u)
```

If there's a new column or a renamed column:
1. Update the staging model (`stg_<source>__<entity>.sql`) to handle both shapes during transition.
2. Add a comment with a TODO and a removal date.
3. Notify the user. Schema drift is a signal upstream owner changed something.

## Step 4 — Recovery

- **Retry** (auth, upstream outage, transient): `python pipelines/ingest_<source>.py --date <YYYY-MM-DD>`
- **Backfill** (after a code fix): use the `backfill-data` skill.
- **Skip** (data really is missing at the source): write a marker file `data/raw/<source>/<date>/_EMPTY` and document in CHANGELOG.

## Step 5 — Prevention

After every real incident, add either:
- A new test in `scripts/data_quality.py`, or
- A new check in the `pii-check` / `pre-sql-execute` hook, or
- A note in CLAUDE.md if the lesson is conventional.

Every postmortem produces at least one of those. No exceptions.

## When to escalate to the user

- Auth failures (don't assume which credential is stale).
- Anything destructive (re-ingesting on top of existing data without explicit OK).
- More than one source failing simultaneously — that's an infra issue, not a pipeline issue.
