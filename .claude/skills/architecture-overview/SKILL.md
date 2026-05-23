---
name: architecture-overview
description: Use this skill when the user asks how this project works end-to-end, what the data flow is, where the raw data comes from, whether the data is real or dummy/synthetic, what each step does, how the pieces fit together, or how the Claude Code primitives (CLAUDE.md, skills, hooks, subagents, MCP servers) map onto the data flow. Triggers include "how does this work", "what's the data flow", "where does the data come from", "is this real data", "explain the architecture", "walk me through it", "what happens when I run X". Points at docs/ARCHITECTURE.md, which is the canonical answer. Don't reinvent the explanation - read the doc.
---

# Architecture overview

When this skill fires, the user wants to understand how the project's data
flow works end-to-end. The doc has the diagram, the per-step detail, the
data-source provenance (real vs synthetic), and the map of Claude Code
primitives onto the flow.

## Procedure

1. Read `docs/ARCHITECTURE.md` from the repo root. It contains:
   - "Is it real or dummy data?" - the most common follow-up question
   - The five-step ASCII flow diagram (API → ingest → land → load → stage →
     mart → audit)
   - Per-step detail with file references
   - A table mapping each Claude Code primitive (CLAUDE.md, skills, hooks,
     subagents, MCP servers, verify.sh) to where it fires in the flow
   - The one-command orchestrator version (`scripts/run.py`)
   - How to plug in a new source

2. Answer the user's specific question by quoting or paraphrasing the
   relevant section. Don't dump the whole doc - they probably asked one
   focused question (e.g. "where does the data come from?"). Give that
   answer first, then offer the wider picture if useful.

3. If the user wants to *see* the flow run, the cheat-sheet is in the doc's
   "What you can see at each step" section - copy those commands.

4. If the user wants to *modify* the flow (add a source, add a mart), don't
   do the work here. Hand off to the relevant doer skill: `create-pipeline`
   for ingestion, `add-dbt-model` for staging/marts. This skill is the
   meta-guide.

## Don't

- Don't reinvent or summarize from memory - the doc is the source of truth
  and may have been updated.
- Don't load this skill alongside the doer skills (`create-pipeline`,
  `add-dbt-model`, etc.) - they have their own runbooks. This skill is for
  *understanding*, not *changing*.
- Don't confuse this with `agent-workflows` - that one is about *how to
  drive the agent* (what prompts to type). This one is about *what the
  project does at runtime*.
