---
name: agent-workflows
description: Use this skill when the user asks how to use this project's skills/subagents, how to add a new source/model end-to-end, what the one-prompt workflow is, how the agent setup saves tokens, or any "how do I drive Claude on this project?" question. Triggers include "how do I add a source", "what's the workflow for X", "how does the agent setup work", "show me how to use the skills", "what should I type to do Y". Points at docs/AGENT_WORKFLOWS.md, which contains the full guide. Don't reinvent the explanation — read the doc and follow it.
---

# Agent workflows guide

When this skill fires, the user wants to understand or use the project's
agent-driven workflows (add a source, add a model, backfill, debug, audit).

## Procedure

1. Read `docs/AGENT_WORKFLOWS.md` from the repo root. It is the canonical guide
   and contains:
   - The cheat-sheet table of one-prompt recipes
   - A worked example of "add a new source end-to-end"
   - The other recurring workflows (mart, backfill, debug, audit, review)
   - The token-efficiency rationale (why skills/subagents/hooks save context
     budget vs a monolithic prompt)
   - When to be explicit about naming a tool vs letting the agent route

2. Answer the user's specific question by quoting or paraphrasing the relevant
   section. Don't dump the whole doc back at them — they probably want one
   answer (e.g. "what prompt do I type to add a Stripe pipeline?"), not the
   full tour.

3. If the user wants to *do* one of the workflows (not just learn about it),
   let the underlying skill or subagent take over — `create-pipeline`,
   `add-dbt-model`, `pipeline-builder`, etc. This skill is the meta-guide,
   not the doer.

## Don't

- Don't reinvent or summarize from memory. The doc is the source of truth and
  may have been updated.
- Don't load this skill alongside the workflow it describes (e.g. if the user
  says "add a Stripe pipeline," `create-pipeline` is the right skill — not
  this one).
