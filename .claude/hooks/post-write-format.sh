#!/usr/bin/env bash
# post-write-format.sh
#
# Fires on PostToolUse for Write/Edit when the target is a .sql or .py file.
# Runs the project formatter and reports any remaining violations.
#
# This hook is NOT a blocker (exit 0 always). Its job is to keep the codebase
# tidy without nagging Claude mid-edit. Real CI runs the same tools as a blocker.

set -euo pipefail

payload="$(cat)"
path="$(printf '%s' "$payload" | grep -oE '"(file_path|path)"[[:space:]]*:[[:space:]]*"[^"]+"' \
       | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"

[ -z "$path" ] && exit 0
[ ! -f "$path" ] && exit 0

case "$path" in
  *.sql)
    if command -v sqlfluff >/dev/null 2>&1; then
      sqlfluff fix --dialect duckdb "$path" >/dev/null 2>&1 || true
      # Report remaining issues, but don't block
      if ! sqlfluff lint --dialect duckdb "$path" >/dev/null 2>&1; then
        echo "ℹ️  sqlfluff: $path still has lint violations after autofix." >&2
        sqlfluff lint --dialect duckdb "$path" 2>&1 | head -20 >&2 || true
      fi
    fi
    ;;
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      ruff format "$path" >/dev/null 2>&1 || true
      ruff check --fix "$path" >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
