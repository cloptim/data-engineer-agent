# DataOps Agent - A Claude Code Architecture

A small but realistic data engineering project where Claude Code is wired up to
behave like a senior data engineer on the team: it knows the conventions, refuses
to do dangerous things, delegates specialized work to focused subagents, and
connects to the warehouse through a structured protocol instead of raw shell.

The codebase itself is intentionally modest, one ingestion pipeline (GitHub events),
a staging + mart dbt model, an orchestrator, and a quality checker. **The interesting
part is what's in `.claude/`**, which is where Claude Code's five primitives are
wired together to make the agent actually useful.

---

## What this is supposed to demonstrate

> Each Claude Code primitive has a *responsibility boundary*. Putting the right
> concern in the right primitive is the difference between an AI that helps and
> an AI that quietly creates incidents.

So instead of cramming everything into one giant system prompt, this project uses:

| Primitive | What it does here | Why it belongs in this layer |
|---|---|---|
| **`CLAUDE.md`** | Project conventions, tech choices, "house rules" | Persistent context. Loaded every session. Don't put workflows here, they bloat the main context. |
| **Skills** (`.claude/skills/`) | On-demand runbooks for recurring tasks (new pipeline, new model, backfill, debug) | Loaded only when Claude judges them relevant. Keeps the main context lean. |
| **Hooks** (`.claude/hooks/`) | Deterministic shell scripts that block destructive SQL and PII leaks | These are *enforcement*, not suggestion. A model can be talked into ignoring CLAUDE.md; a `exit 2` from a hook is non-negotiable. |
| **Subagents** (`.claude/agents/`) | Isolated specialists for SQL review, quality auditing, incident debugging, and pipeline scaffolding | Their verbose work (log dumps, multi-file scans) happens in a separate context window and never pollutes the main session. |
| **MCP servers** (`settings.json`) | Read-only DuckDB connection + scoped filesystem access to `data/` | Structured tool access. Better than handing Claude a generic shell and hoping. |
| **`settings.json`** | Wires the above together, plus permissions | Project-level config that's checked into git so the whole team shares the same agent setup. |

---

## Layout

```
.
├── CLAUDE.md                          # The project "constitution" Claude reads first
├── .claude/
│   ├── settings.json                  # Hooks, MCP servers, permissions - all wired here
│   ├── skills/                        # On-demand runbooks (loaded only when needed)
│   │   ├── create-pipeline/SKILL.md
│   │   ├── add-dbt-model/SKILL.md
│   │   ├── debug-pipeline-failure/SKILL.md
│   │   └── backfill-data/SKILL.md
│   ├── agents/                        # Subagents with isolated contexts
│   │   ├── sql-reviewer.md
│   │   ├── data-quality-auditor.md
│   │   ├── pipeline-debugger.md
│   │   └── pipeline-builder.md
│   └── hooks/                         # Deterministic enforcement
│       ├── pre-sql-execute.sh         # Blocks DROP/TRUNCATE/DELETE-without-WHERE
│       ├── pii-check.sh               # Blocks unhashed PII in staging models
│       └── post-write-format.sh       # Auto-formats SQL/Python after edits
├── pipelines/
│   └── ingest_github.py               # Example pipeline following the project's conventions
├── dbt_project/
│   ├── dbt_project.yml
│   └── models/
│       ├── staging/
│       │   ├── stg_github__events.sql
│       │   └── schema.yml
│       └── marts/
│           ├── events_daily.sql
│           └── schema.yml
├── scripts/
│   ├── run.py                         # Demo orchestrator
│   ├── load_raw.py                    # JSONL → DuckDB loader (the "raw → warehouse" hop)
│   ├── data_quality.py                # Read-only DQ checks (the auditor subagent uses this)
│   ├── verify.sh                      # Quality gate - pre-commit, CI, and Claude all call this
│   └── test-hooks.sh                  # Proves the hooks actually work - 12/12 passing
├── data/
│   ├── raw/                           # Immutable, partitioned by date
│   └── processed/
├── .pre-commit-config.yaml            # Local git pre-commit gate (delegates to verify.sh)
├── .github/workflows/ci.yml           # Server-side CI gate (delegates to verify.sh)
├── .sqlfluff                          # SQL lint config matching CLAUDE.md style
├── requirements.txt                   # Python deps
└── CHANGELOG.md
```

---

## The five primitives, in detail

### 1. `CLAUDE.md` - the memory layer

This is the only file Claude Code reads automatically every session. It contains:

- **Hard rules** that override the model's defaults (raw data is immutable, schema changes
  need migrations, PII must be hashed in staging).
- **Conventions** (naming, SQL style, Python deps) - so Claude doesn't propose pandas when
  the project uses polars.
- **Layout map** - where to put new files.
- **Delegation guide** - when to spawn which subagent.

What it deliberately does *not* contain: procedural how-tos. Those bloat the main context.
They go in skills.

### 2. Skills - the knowledge layer (loaded on demand)

Each skill is a single `SKILL.md` file with YAML frontmatter declaring its trigger
conditions. Claude loads it only when it decides the skill is relevant. The four here:

- **`create-pipeline`** - scaffolds a new ingestion script with the project's idempotency
  pattern (date-partitioned writes, `_FAILED` sentinel, env-var auth).
- **`add-dbt-model`** - creates a staging or mart model with the right naming, PII handling,
  and test entries.
- **`debug-pipeline-failure`** - a real triage runbook: locate the failure, classify it
  (auth / schema drift / upstream / our bug), diff partitions, propose a fix.
- **`backfill-data`** - the safe procedure: snapshot first, run day-by-day, validate, only
  then delete the snapshot. The kind of thing you don't want an LLM improvising.

Why skills instead of one giant prompt: a 12-page instruction set in the system prompt
crowds out the actual work. Skills let Claude pull in 200 lines of guidance only when
relevant, then drop it.

### 3. Hooks - the guardrail layer (deterministic)

Three hooks, all reading the Claude Code hook payload from stdin and exiting 0 (allow) or
2 (hard block).

- **`pre-sql-execute.sh`** - Fires on `PreToolUse` for Bash. Greps for `DROP TABLE`,
  `TRUNCATE`, unqualified `DELETE`, `ALTER ... DROP COLUMN`. Blocks unless the operator
  has included an explicit `I_HAVE_BACKED_UP` override. **This is the single most important
  file in the project** - it's the thing that lets you run an autonomous agent against a
  real warehouse without losing sleep.
- **`pii-check.sh`** - Fires on `PreToolUse` for Write/Edit on files matching
  `dbt_project/models/staging/*.sql`. Scans for raw `email|phone|ssn|dob|address`
  columns appearing in a SELECT without a corresponding `md5(...)`. Blocks if found.
- **`post-write-format.sh`** - Fires on `PostToolUse`. Runs `sqlfluff fix` on SQL files
  and `ruff format` on Python. Non-blocking - it just keeps the codebase tidy.

The point of hooks: a model can be cajoled, jailbroken, or simply confused into ignoring
a rule in `CLAUDE.md`. A hook is deterministic shell code. It either fires or it doesn't.

**Tested:** `scripts/test-hooks.sh` runs 12 cases against simulated payloads. Currently 12/12 pass.

### 4. Subagents - the delegation layer (isolated contexts)

Each subagent is a markdown file in `.claude/agents/` with its own system prompt, tool
allowlist, and operating procedure. When Claude spawns one, the subagent's work happens
in a *separate context window* - its log digging, file scans, and intermediate outputs
never appear in the main session.

- **`sql-reviewer`** - Read-only. Reviews proposed SQL/dbt changes for correctness, PII
  compliance, conventions, performance, and idempotency. Returns a verdict (approve / request
  changes / block) with line-level comments. Invoked automatically before non-trivial commits.
- **`data-quality-auditor`** - Read-only. Runs the standard audit checklist (freshness, row
  count anomaly, null rate, PK integrity, PII leak scan) and returns a structured report.
- **`pipeline-debugger`** - Triages failed runs. Finds `_FAILED` sentinels, classifies the
  failure, diffs schemas if drift, proposes a fix. Hands the actual fix back to the main agent.
- **`pipeline-builder`** - Builds a full new source end-to-end (script + model + tests +
  orchestration entry) without coming back for intermediate approvals on boilerplate.

Why subagents matter: the main agent stays focused on user dialogue and planning. A bug
hunt that involves reading 30 log files and comparing two raw partitions happens in a
sandbox. When the subagent returns, the main session gets a clean two-paragraph summary,
not 30 log files.

### 5. MCP servers - the distribution layer (structured external access)

`settings.json` declares two MCP servers:

- **`warehouse`** - A DuckDB MCP server in **read-only mode** pointed at `warehouse.duckdb`.
  Claude can list tables, describe schemas, and run SELECT queries through structured tool
  calls - not by shelling out to `duckdb` and parsing text output.
- **`filesystem`** - A filesystem MCP server scoped to `./data/`. Lets Claude inspect raw
  partitions and processed files without granting unrestricted file access.

Why MCP instead of plain Bash: structured tools have schemas, return typed data, and are
naturally limited in scope. The DuckDB MCP server's read-only flag is a second layer of
defense alongside the `pre-sql-execute` hook - even if the hook were bypassed, the
connection itself refuses writes.

---

## Trying it out

```bash
# 1. Install deps (minimal - duckdb for the warehouse, sqlfluff/ruff for formatting) in a Python Virtual Environment
pip install duckdb dbt-duckdb sqlfluff ruff

# 2. Install dbt package dependencies (one-time - needed because marts tests use dbt_utils)
cd dbt_project && dbt deps && cd ..

# 3. Run the example pipeline (writes JSONL to data/raw/github/<date>/)
#    No auth needed for low-rate GitHub API.
python pipelines/ingest_github.py

# 4. Load raw JSONL into the warehouse (creates github.events_raw in warehouse.duckdb)
#    This is the "raw → warehouse" hop. Must run before dbt build.
python scripts/load_raw.py

# 5. Build the warehouse
#    The dbt connection is configured by dbt_project/profiles.yml (checked into the repo,
#    points at ../warehouse.duckdb). No ~/.dbt setup required.
cd dbt_project && dbt build && cd ..

# 6. Audit
python scripts/data_quality.py

# 7. Verify the hooks block what they're supposed to
./scripts/test-hooks.sh
```

> **If `dbt_project/profiles.yml` doesn't exist** (e.g. it's gitignored in your fork),
> create it with:
>
> ```yaml
> # dbt_project/profiles.yml
> dataops_demo:
>   target: dev
>   outputs:
>     dev:
>       type: duckdb
>       path: ../warehouse.duckdb
>       threads: 4
> ```
>
> Or put the same content (with an absolute `path:`) in `~/.dbt/profiles.yml` if you
> prefer the conventional global location.

To use this as a Claude Code project, install Claude Code, `cd` into this directory, and
start a session. The agent will read `CLAUDE.md`, hooks will fire on tool calls, and
subagents are available via the Task tool.

---

## Driving the agent (one prompt, end-to-end)

Once the project is set up, the recurring data-engineering work adding a source,
adding a mart, backfilling, debugging a failed run, auditing the warehouse, is each
**one prompt**. The agent loads the relevant skill, delegates the heavy lifting to a
subagent in an isolated context window, and hands you back a clean diff plus a
summary. You don't write the boilerplate and you don't burn tokens explaining the
project on every turn - the conventions live in `CLAUDE.md`, the runbooks live in
skills, and the verbose work happens elsewhere.

The cheat sheet:

| Goal                            | Example prompt                                          |
|---|---|
| Add a new source end-to-end     | `Add a Stripe charges pipeline end-to-end.`             |
| Add a new mart                  | `Add a daily aggregate of events by repo and type.`     |
| Backfill a date range           | `Backfill the last 30 days of GitHub events.`           |
| Diagnose a pipeline failure     | `Yesterday's GitHub pipeline failed - what happened?`   |
| Audit the warehouse             | `Audit the warehouse.`                                  |

**See [`docs/AGENT_WORKFLOWS.md`](docs/AGENT_WORKFLOWS.md)** for the full walkthrough:
what fires when, what you don't have to do, and the design rationale for why this
setup uses ~10× fewer tokens than the obvious "put everything in the system prompt"
approach. The `agent-workflows` skill points Claude at that doc automatically when
you ask "how do I use this project."

**See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** if you want to understand what
*actually happens* at runtime - where the data comes from (live GitHub API, not
fixtures), how it moves through the five steps (ingest → land → load → stage →
mart → audit), and how each Claude Code primitive maps onto a specific point in
the flow. The `architecture-overview` skill points Claude at that doc when you
ask "how does this work?"

---

## Quality gate (nothing breaks on commit)

The Claude Code hooks in `.claude/hooks/` only fire when Claude is the actor. A
colleague running `git commit` directly bypasses every one of them. So this
project layers in a second, agent-independent gate that catches everyone - Claude,
humans, bots, force-pushes:

| Layer | What fires | Where it lives | Audience |
|---|---|---|---|
| Claude Code hooks | PII check, destructive-SQL block, auto-format | `.claude/hooks/` | Claude only |
| `scripts/verify.sh` | ruff, sqlfluff, dbt parse, hook self-tests, dbt build (`--full`), data quality (`--full`) | Inside the repo | Anyone - single source of truth |
| Git pre-commit | Standard hygiene + `verify.sh` | `.pre-commit-config.yaml` | Local commits |
| GitHub Actions CI | `verify.sh --full` after ingest + load | `.github/workflows/ci.yml` | Every push / PR |
| `quality-gate` skill | Runs `verify.sh`, explains failures, proposes fixes | `.claude/skills/quality-gate/` | Claude (agent-driven) |

The key design move: **`scripts/verify.sh` is the single source of truth.** The
pre-commit hook calls it, CI calls it, and the `quality-gate` skill calls it.
They can't drift apart because there's only one definition of "passing."

To bring up the local gate after cloning:

```bash
pip install -r requirements.txt
pre-commit install            # wires .pre-commit-config.yaml into .git/hooks/
scripts/verify.sh             # static checks (fast)
scripts/verify.sh --full      # also runs dbt build + data quality
```

In a Claude Code session, `"verify my changes"` or `"is this ready to commit?"`
triggers the `quality-gate` skill - which runs the same script, but adds the
ability to *reason about* failures (explain the sqlfluff violation, propose a
fix, notice that a schema change will break a downstream mart). That's the
agent-layer-on-top-of-deterministic-layer pattern this project exists to
demonstrate.

---

## Design notes

**Why this combination of primitives, and not others.** Each primitive earns its place:

- I considered putting the PII rule in `CLAUDE.md` only. Rejected: instructions in markdown
  are advisory; the model can be talked out of them. A hook can't be talked out of anything.
- I considered making `sql-reviewer` a skill instead of a subagent. Rejected: review work
  involves reading many files and producing verbose output, which is exactly what subagents
  isolate well. A skill runs in the main context.
- I considered exposing the warehouse via plain Bash. Rejected: structured MCP access is
  both safer (read-only flag) and more efficient (typed results, no shell escaping).
- I considered one mega-agent that does everything. Rejected: a 4000-token system prompt
  trying to be ingestion + transform + review + audit + debug is worse at every individual
  task than four 600-token specialists.

**What's deliberately missing.** Plugins. They're the "distribution" layer in the
architecture - packaging skills + hooks + subagents + MCP server configs into a single
installable unit so multiple repos can share the same agent setup. For a single-repo
demo, plugins don't add value; everything's already in `.claude/`. The trigger to
convert is a concrete second consumer - another team, another project, or a community
publication. Until that exists, plugin packaging is premature.

The interesting property worth calling out: this project is **plugin-ready by
accident.** The `.claude/` directory is cleanly separated from the demo's code
(`pipelines/`, `dbt_project/`, `scripts/`), so lifting it out is mostly mechanical.
If/when that becomes worth doing, there are three natural extraction candidates,
ordered from broadest audience to narrowest:

1. **`agent-quality-gate` plugin** - `scripts/verify.sh` + the `quality-gate` skill +
   a `.pre-commit-config.yaml` template + a `.github/workflows/ci.yml` template.
   Not data-engineering-specific. Any repo with linters and tests can use the
   "single script invoked by pre-commit + CI + a Claude skill" pattern. The most
   broadly reusable piece of the demo.

2. **`data-engineering-guardrails` plugin** - the three hooks (`pre-sql-execute`,
   `pii-check`, `post-write-format`) plus the hard-rules section of `CLAUDE.md`.
   No opinion on the stack. Anyone running a warehouse where humans or LLMs might
   issue destructive SQL or leak PII benefits. Highest leverage per line of code
   because hooks are deterministic and unbypassable.

3. **`dbt-duckdb-toolkit` plugin** - the four data-engineering skills
   (`create-pipeline`, `add-dbt-model`, `backfill-data`, `debug-pipeline-failure`)
   plus the four subagents (`sql-reviewer`, `data-quality-auditor`,
   `pipeline-debugger`, `pipeline-builder`) plus the dbt-specific conventions in
   `CLAUDE.md`. Most opinionated - assumes the staging/marts pattern, the
   partition-by-date pattern, the `_FAILED` sentinel. Narrower audience but
   higher value to that audience.

If you ever do publish them, the suggested pattern is: keep this repo as the
*reference implementation* (it stays useful because plugins are pure config -
they don't show the primitives in concert with real data flowing), and have the
demo install its own plugin to dogfood it.

**Summary.** The real win is mundane: write the rules
down once (`CLAUDE.md`), make the dangerous ones unbypassable (hooks), keep the noisy work
in a separate room (subagents) and give the agent structured access to the systems that
matter (MCP).
