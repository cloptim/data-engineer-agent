#!/usr/bin/env bash
# pre-sql-execute.sh
#
# Fires on PreToolUse for Bash and Write tools.
# Reads the proposed command/content from stdin (as JSON, per Claude Code hook protocol)
# and blocks if it contains destructive SQL without an explicit "I_HAVE_BACKED_UP" token.
#
# Exit codes:
#   0 → allow the tool call
#   2 → block the tool call (Claude Code respects this hard-stop)
#
# Reference: hooks fire at lifecycle points (PreToolUse, PostToolUse, UserPromptSubmit, etc.)
# and can deterministically block actions Claude would otherwise take.

set -euo pipefail

# Read the hook payload from stdin
payload="$(cat)"

# Extract the proposed command or file content. We use a tolerant pattern
# because the exact JSON shape differs by tool.
content="$(printf '%s' "$payload" | tr -d '\n')"

# Patterns we consider destructive.
# Order matters: more specific first, so we can produce a useful error message.
declare -a DESTRUCTIVE_PATTERNS=(
  "DROP[[:space:]]+TABLE"
  "DROP[[:space:]]+DATABASE"
  "DROP[[:space:]]+SCHEMA"
  "TRUNCATE[[:space:]]+TABLE"
  "TRUNCATE[[:space:]]+[A-Za-z_]+"
  "ALTER[[:space:]]+TABLE[[:space:]]+[A-Za-z_.]+[[:space:]]+DROP[[:space:]]+COLUMN"
  "DELETE[[:space:]]+FROM[[:space:]]+[A-Za-z_.]+[[:space:]]*;"  # DELETE without WHERE
)

# Case-insensitive grep with extended regex
for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
  if printf '%s' "$content" | grep -Eqi "$pattern"; then
    # Check for the explicit override token
    if printf '%s' "$content" | grep -q "I_HAVE_BACKED_UP"; then
      # Override accepted — log it loudly to stderr so it shows up in the transcript
      echo "⚠️  Destructive SQL allowed because override token is present." >&2
      echo "    Pattern matched: $pattern" >&2
      exit 0
    fi

    cat >&2 <<EOF
🛑 Blocked: destructive SQL detected.

Pattern matched: $pattern

This project's policy (see CLAUDE.md) requires explicit human confirmation before
running DROP, TRUNCATE, ALTER ... DROP COLUMN, or unqualified DELETE.

If you really need to run this:
  1. Snapshot the affected table.
  2. Document the change in CHANGELOG.md.
  3. Add the comment '-- I_HAVE_BACKED_UP' on a line in the SQL.
  4. Try again.

If you didn't intend this, check whether you meant a CREATE OR REPLACE,
a soft-delete UPDATE, or a dbt full-refresh instead.
EOF
    exit 2
  fi
done

exit 0
