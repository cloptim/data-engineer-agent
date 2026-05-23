---
name: backfill-data
description: Use this skill when the user wants to re-ingest historical data for a pipeline. Triggers include "backfill X", "rerun for last week", "I need the last 30 days of Y reloaded", "the data is wrong, reload it". Provides the safe procedure that preserves immutability of good partitions and avoids accidentally trashing the warehouse.
---

# Backfill a date range

**Backfills are dangerous.** They re-write data that downstream consumers may have already used.
Follow the procedure exactly.

## Pre-flight (do all of this before touching anything)

1. **Confirm the range with the user.** Echo back the start date, end date, and the pipeline name.
   Get explicit "yes" before proceeding. Date ranges are easy to fat-finger.
2. **Confirm the reason.** "Why are we backfilling?" If it's "schema drift fix" or "bug fix",
   good. If it's "I'm not sure, the numbers look weird" - stop and run data quality checks first.
3. **Estimate cost.** API calls, time, storage. Tell the user before they pull the trigger.

## Procedure

1. **Snapshot the existing partitions** (so we can roll back):
   ```bash
   for d in data/raw/<source>/<date>; do
       mv "$d" "${d}.bak.$(date +%s)"
   done
   ```
   Do NOT delete the originals until the backfill succeeds and is validated.

2. **Run the pipeline per-date in a loop** (not as one big range - partition isolation matters):
   ```bash
   for d in $(seq <start> <end>); do
       python pipelines/ingest_<source>.py --date "$d" || { echo "FAILED on $d"; break; }
   done
   ```
   If any single day fails, STOP. Don't continue silently.

3. **Re-run dbt for the affected partitions only:**
   ```bash
   cd dbt_project && dbt build --select +stg_<source>__<entity>+ --vars '{start_date: <start>, end_date: <end>}'
   ```

4. **Run data quality:**
   ```bash
   python scripts/data_quality.py --since <start>
   ```

5. **If everything is green**, delete the `.bak.*` snapshots. If anything is red, restore them:
   ```bash
   for b in data/raw/<source>/*.bak.*; do
       orig="${b%.bak.*}"
       rm -rf "$orig" && mv "$b" "$orig"
   done
   ```

## Things to never do during a backfill

- `DROP` or `TRUNCATE` the warehouse table. (The hook will block you anyway.)
- Run on prod warehouse without a staging environment first if the dataset is large.
- Skip the snapshot step "to save time". You will regret this exactly once.
- Backfill more than 90 days without explicit user approval per-chunk.

## Document it

Add an entry to `CHANGELOG.md`:
```
## Backfill <YYYY-MM-DD>
- Source: <source>
- Range: <start> → <end>
- Reason: <one line>
- Outcome: <rows changed, anything notable>
```
