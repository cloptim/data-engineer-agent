---
name: quality-gate
description: Use this skill when the user wants to verify their changes pass the project's "done" criteria before committing, merging, or pushing. Triggers include "is this ready to commit", "verify my changes", "run the checks", "check before push", "what's blocking merge", "did everything pass", "run verify". Different from sql-reviewer (which is specifically SQL code review) — this is the full quality gate: lint, parse, hook self-tests, dbt build, data quality. Runs scripts/verify.sh, parses the output, explains any failures, and proposes fixes.
---

# Project quality gate

When this skill fires, the user wants to confirm their changes are safe to ship.
The deterministic answer comes from `scripts/verify.sh` — your job is to run it,
interpret the result, and (when it fails) explain what broke and propose a fix.

## Procedure

1. **Decide which mode to run.**
   - Default to `scripts/verify.sh` (fast static checks: ruff, sqlfluff, dbt
     parse, hook self-tests). This is what fires in the local pre-commit gate.
   - If the user said "full", "everything", "before merge", or you can see
     they've changed `.sql`/`pipelines/`/`scripts/load_raw.py`, run
     `scripts/verify.sh --full` (also runs dbt build + data quality, requires
     a populated `warehouse.duckdb`).
   - If you need machine-readable output to filter or summarize, use `--json`.

2. **Run it. Don't reinvent it.** The script is the source of truth — the
   pre-commit hook and CI both call it. If `verify.sh` is green, the change
   is good by definition.

3. **If it passes:** report which checks ran and confirm green. Keep it brief
   — the user wanted a yes/no, not a tour.

4. **If it fails:**
   a. Read the captured output for the failed check(s).
   b. Classify the failure:
      - **Lint** (ruff / sqlfluff) — usually mechanical. Propose running the
        appropriate `--fix` and re-running verify.
      - **dbt parse** — schema.yml or model file syntax error. Read the file
        and propose a fix.
      - **Hook self-tests** — a hook regression. Read `scripts/test-hooks.sh`
        output, find the broken case, propose the fix.
      - **dbt build** — model logic / SQL error. Look at the compiled model in
        `dbt_project/target/compiled/` for the actual SQL that ran, then read
        the source model and propose a fix.
      - **Data quality** — a real DQ failure (freshness, PK uniqueness, null
        spike, PII leak). This is the kind of finding worth surfacing
        clearly — it's catching a real warehouse issue, not a code style nit.
   c. Propose **one** fix and ask the user before applying. Quality-gate
      failures are sometimes intentional (e.g. a deliberate schema migration
      in progress); don't auto-fix.

5. **After a fix, re-run verify.** Confirm the fix actually resolved the
   failure and didn't break a different check.

## Don't

- **Don't bypass the gate.** Never suggest `git commit --no-verify` or editing
  `.pre-commit-config.yaml` to skip a check. If the user wants to skip, they'll
  do it themselves.
- **Don't reimplement the checks.** If you find yourself manually running ruff
  / sqlfluff / dbt separately, stop — call `verify.sh` so the gate stays
  consistent with pre-commit and CI.
- **Don't load alongside `sql-reviewer`.** They have overlapping concerns but
  different jobs: `sql-reviewer` does line-level code review of a specific SQL
  change; this skill is the unconditional pre-commit gate. If the user wants
  both, run this first, then invoke `sql-reviewer` separately.
- **Don't suppress real findings to make the gate pass.** If sqlfluff is
  complaining about a real style violation, fix the SQL or update the project
  style (CLAUDE.md + `.sqlfluff`) — don't add the file to an ignore list.

## Example interaction

> User: "Verify before I push."
>
> You: *runs `scripts/verify.sh`*
>
> "Static checks all green — ruff, sqlfluff, dbt parse, hook tests (12/12).
> Skipped the full integration checks (dbt build + data quality) since you
> didn't ask for `--full`. Want me to run those too before you push?"

vs.

> User: "Run the full quality gate."
>
> You: *runs `scripts/verify.sh --full`*
>
> "All six checks passed: ruff, sqlfluff, dbt parse, hook self-tests, dbt
> build (12 models + tests), data quality (freshness/PK/nulls/PII all green).
> Safe to merge."

vs. failure:

> You: *runs `scripts/verify.sh`*
>
> "Failed on sqlfluff: `dbt_project/models/staging/stg_stripe__charges.sql`
> has two LT05 violations (line too long, 110 > 100). These are fixable —
> `sqlfluff fix` will wrap them. Want me to run it?"
