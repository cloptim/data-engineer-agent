# Agent Workflows - driving this project end-to-end with one prompt

The point of the agent setup in `.claude/` is that recurring data-engineering work
- adding a source, adding a model, backfilling, debugging a failure, auditing -
should each be **one prompt**. The conventions live in `CLAUDE.md`, the runbooks
live in skills, the heavy lifting happens in subagents. You don't write the
boilerplate and you don't burn tokens explaining the project.

This guide is the usage companion to the architectural pitch in the README.
The README answers "why is this structured this way?" - this doc answers
"so what do I actually type?"

---

## TL;DR - the prompts

In a Claude Code session in this repo, any of these is a complete request:

| Goal                            | Example prompt                                                |
|---|---|
| Add a new source end-to-end     | `Add a Stripe charges pipeline end-to-end.`                   |
| Just the ingestion script       | `Add a pipeline for Stripe charges.`                          |
| Add a new mart                  | `Add a daily aggregate of events by repo and type.`           |
| Add a new staging model         | `Create a staging model for the new shopify orders source.`   |
| Backfill a date range           | `Backfill the last 30 days of GitHub events.`                 |
| Diagnose a pipeline failure     | `Yesterday's GitHub pipeline failed - what happened?`         |
| Audit the warehouse             | `Audit the warehouse.`                                        |
| Review a SQL change             | `Review this SQL before I merge.`                             |
| Verify before commit/push       | `Is this ready to commit?`  /  `Run the quality gate.`        |

Each prompt routes to a different skill or subagent (or both). The next sections
walk through *how* and *why* - but if all you want is the cheat sheet, you have
it.

---

## Headline workflow: add a new source

The naive way to add a new source involves: reading existing pipeline code to
copy its shape, hand-writing a similar script, remembering the partition-by-date
convention, adding a loader entry, adding an orchestrator entry, writing the
staging SQL, remembering the PII hashing rule, adding tests, running the
formatters. Ten or fifteen manual steps; easy to miss one.

The agent-driven way is one sentence:

> **You:** Add a Stripe charges pipeline end-to-end.

What happens in response, in one pass:

1. **`create-pipeline` skill** loads (the model recognizes the trigger phrase from
   its frontmatter) and follows the runbook to write
   `pipelines/ingest_stripe.py` - partition-by-date, `_FAILED` sentinel, env-var
   auth, JSON-lines logging. The conventions are non-negotiable because the skill
   says so; the model doesn't have to invent them.

2. **`pipeline-builder` subagent** spawns (because you asked for end-to-end, not
   just the script). It runs in its own context window and handles:
   - Loader entry in `scripts/load_raw.py` (a new `LOADERS["stripe"]` block
     with the right flatten SQL - `customer.email` → `customer_email` etc.)
   - `PIPELINES` entry in `scripts/run.py`
   - `add-dbt-model` skill invocation for the staging model, producing
     `dbt_project/models/staging/stg_stripe__charges.sql` plus `schema.yml`
     test entries (`not_null` and `unique` on the PK, per project convention)
   - Optional mart if you mentioned one (e.g. "...and a daily charges mart")

3. **`pii-check.sh` hook** fires on each staging-model write. If `email` appears
   in a `SELECT` without a corresponding `md5(...)`, the write is **blocked**
   (`exit 2`). The hook is shell, not LLM - it can't be argued with.

4. **`post-write-format.sh` hook** runs `sqlfluff fix` on each `.sql` write and
   `ruff format` on each `.py` write. Non-blocking; you don't see it happen.

5. **`sql-reviewer` subagent** runs automatically against any non-trivial SQL
   change before the agent reports done. You get a verdict (approve / request
   changes) with line-level comments, in a clean summary - not a 500-line
   stream of its analysis.

6. **Summary returned to you.** Five-ish files diffed, a one-paragraph rationale,
   a list of what tests passed, and what (if anything) needs your attention.

What you do: review the diff, run `python pipelines/ingest_stripe.py` to confirm
ingestion works, then `python scripts/load_raw.py && cd dbt_project && dbt build`.
If anything fails, the next prompt is just `the stripe pipeline failed - fix it`,
which routes to the `pipeline-debugger` subagent.

### What you didn't have to do

This is the value prop, stated explicitly:

- **Explain the conventions.** `CLAUDE.md` did it, once, when the session started.
- **Quote the PII rule.** The hook enforces it deterministically. You never typed
  the word "PII" in your prompt.
- **Specify the tests.** The skill knows every mart needs `not_null` + `unique`
  on its PK; the model didn't have to guess.
- **Ask for formatting.** The post-write hook ran `sqlfluff`/`ruff` itself.
- **Ask for a review.** `sql-reviewer` auto-invoked because the subagent's
  operating procedure says so.
- **Babysit the long task.** The subagent runs in its own context window - its
  30-file exploration and intermediate edits never enter your main session.

---

## Other recurring workflows

Same one-prompt pattern; different skill or subagent fires.

### Add a mart

> `Add a daily aggregate of events by repo and type.`

Routes to `add-dbt-model` skill. Produces `events_daily.sql` (or whatever name
fits the naming convention `<domain>_<grain>.sql`) plus `schema.yml` test
entries. PK uniqueness via `dbt_utils.unique_combination_of_columns` is added if
the grain is composite. Materialization is `table` (per `dbt_project.yml`).

### Backfill a date range

> `Backfill the last 30 days of GitHub events.`

Routes to the `backfill-data` skill. **The skill is opinionated:** snapshot first,
run day-by-day, validate each partition, only then delete the snapshot. It will
not improvise. This is the kind of operation where you *want* the model
following a runbook instead of being creative - a wrong backfill quietly trashes
the warehouse.

### Diagnose a failure

> `Yesterday's GitHub pipeline failed - what happened?`

Routes to `debug-pipeline-failure` skill + `pipeline-debugger` subagent. The
subagent finds the `_FAILED` sentinel, classifies the failure (auth / schema
drift / upstream / our bug), diffs schemas if drift, and proposes a fix. The
log dumps and stack traces stay in the subagent's context - you see a clean
two-paragraph root-cause summary.

### Audit the warehouse

> `Audit the warehouse.`

Routes to `data-quality-auditor` subagent. Runs the checklist: freshness vs SLA,
row-count anomaly, null-rate spike, PK uniqueness, PII leak scan in marts. The
subagent has read-only warehouse access - it can't modify anything. Output is a
structured report with PASS/FAIL per check.

This is also a good `/schedule` candidate - weekly Monday 9am audit, posted to
wherever you want it.

### Review a SQL change

> `Review this SQL before I merge.`

Routes to `sql-reviewer` subagent (read-only). Checks correctness, PII
compliance, conventions, performance, and idempotency. Returns approve /
request-changes with line-level comments. Won't touch your file.

---

## Why this is token-efficient

The whole architecture is built around one observation: **the obvious way to do
this with an LLM - "put everything in the system prompt" - is wildly wasteful.**
A 4000-token system prompt full of conventions, sample code, PII rules, review
checklists, and debug runbooks gets paid for **every turn**, even when you're
just asking "what's the schema of `github.events_raw`?"

Three design choices fix that:

### 1. Skills are loaded only when relevant

Each skill is a `SKILL.md` file with YAML frontmatter describing *when* it
applies. Claude reads the frontmatter (cheap), decides if the trigger matches,
and pulls the 150-line body into context **only on that turn**. Skip the turn,
skip the cost.

Result: adding a 10th or 20th skill costs nothing on turns where it doesn't
fire. The `create-pipeline` runbook isn't in your context when you're debugging
a failure.

### 2. Subagents have isolated context windows

When `pipeline-builder` runs, its file reads, intermediate edits, tool failures,
and self-corrections all happen in **its own context** - not yours. You get the
conclusion. A 30-file end-to-end scaffold doesn't cost you 30 files' worth of
context budget in the main session.

This is the single biggest token-saver for non-trivial work. A naive setup
that did the same work in the main session would consume tens of thousands of
tokens you'd still be carrying around three turns later.

### 3. Hooks are deterministic shell scripts, not LLM calls

The PII check, the destructive-SQL block, the formatter - none of them spend a
single token. They run as `exit 0` / `exit 2` outside the model. Pure
automation, zero LLM cost, and unbypassable: the model can't talk a hook out of
its decision.

The PII rule lives in shell code (`pii-check.sh`), not in your system prompt.
You pay for it once when the file was written, never again.

### The combined effect

```
                 Naive approach                       This project
              ─────────────────────             ─────────────────────────
System        ~4000 tokens of conventions,      ~600 tokens (CLAUDE.md only)
prompt        sample code, PII rules,           Skills load on demand.
              review checklist, debug
              runbook. Paid every turn.

"Add a        Reads 30 files, writes 5,         pipeline-builder runs in
Stripe        reviews own work, writes 4        a sandbox. Reads its 30
pipeline      more after review. All of         files there. Main context
end-to-end"   it in your main context.          just sees: "done, here's
              ≈ 30k tokens consumed and         what changed."
              still present next turn.          ≈ 1–2k tokens.
```

These numbers are illustrative, not measured - but the order of magnitude is
right. The work happened; the bytes didn't pile up in front of you.

---

## When to be explicit about tools

The agent decides on its own which skill or subagent to fire, based on
trigger-phrase matching against the frontmatter descriptions. Usually that's
fine. Sometimes it's faster to name the tool yourself:

- `Use the pipeline-builder subagent to add a Shopify orders pipeline.`
- `Run the data-quality-auditor subagent.`
- `Use the backfill-data skill for the last 7 days of github.`

This skips the model's own routing decision and is useful when (a) you know
exactly what you want and don't want to be asked clarifying questions, or
(b) you noticed the agent picked the wrong tool last time and want to
correct it.

---

## What this guide deliberately doesn't cover

- **Production scheduling** (cron, Airflow). That's a separate concern - see the
  README section on `scripts/run.py` and `/schedule`. The agent doesn't drive
  daily ETL runs; it builds the things that get scheduled.
- **MCP server usage.** The DuckDB and filesystem MCP servers are how Claude
  reads warehouse state and inspects raw files. They're tools the agent uses
  internally, not workflows you invoke. See `.claude/settings.json` and the
  README.
- **Customizing skills/subagents.** Editing the files in `.claude/skills/` or
  `.claude/agents/` is straightforward - they're just markdown with frontmatter
  - but it's a separate topic from using what's already there.
