#!/usr/bin/env bash
# pii-check.sh
#
# Fires on PreToolUse for Write/Edit when the target is a .sql file under dbt_project/models/.
# Blocks if a staging model selects raw PII columns without hashing.
#
# Heuristic (intentionally tight — false positives are fine, false negatives are not):
#   - File path matches dbt_project/models/staging/*.sql
#   - The SQL contains a bare column name from the PII list in a SELECT/projection context
#   - AND there is no corresponding md5(...)/sha256(...) hash of that column nearby
#
# Exit 2 blocks the write; exit 0 allows.

set -euo pipefail

payload="$(cat)"

# Get the target path. Different tools name this field differently; try the common ones.
path="$(printf '%s' "$payload" | grep -oE '"(file_path|path)"[[:space:]]*:[[:space:]]*"[^"]+"' \
       | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"

# Only enforce in staging models. Marts should already have hashed values from staging,
# and other SQL (tests, macros) is exempt.
case "$path" in
  *dbt_project/models/staging/*.sql) ;;
  *) exit 0 ;;
esac

# Get the file content from the payload. We try a few JSON field names.
content="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    p = json.loads(sys.stdin.read())
    # Try common field names across hook payload shapes
    for key in ("content", "new_str", "file_text", "text"):
        v = p.get(key) or p.get("tool_input", {}).get(key)
        if v:
            print(v); break
except Exception:
    pass
')"

if [ -z "$content" ]; then
  # If we can't read the content, fail open — but log it.
  echo "ℹ️  pii-check: could not parse hook payload, allowing." >&2
  exit 0
fi

PII_COLS=(email phone ssn dob address date_of_birth)
violations=()

for col in "${PII_COLS[@]}"; do
  # Look for the column appearing in a SELECT context (after select or comma)
  # but not as part of a hash function.
  if printf '%s' "$content" | grep -Eiq "(^|,|select)[[:space:]]+${col}([[:space:]]|,|$)"; then
    if ! printf '%s' "$content" | grep -Eiq "(md5|sha256|hash)\([^)]*${col}"; then
      violations+=("$col")
    fi
  fi
done

if [ "${#violations[@]}" -gt 0 ]; then
  cat >&2 <<EOF
🛑 Blocked: PII columns selected without hashing in a staging model.

File: $path
Columns: ${violations[*]}

Project policy (CLAUDE.md) requires PII to be hashed in staging. Use:

    md5(lower(trim(${violations[0]}))) as ${violations[0]}_hash,

…and do not select the raw column.

If this column genuinely isn't PII (e.g., a column named 'address' that holds a wallet
address, not a postal address), rename it to disambiguate, or add a comment
'-- pii-check: not-pii' on the same line and try again.
EOF
  exit 2
fi

exit 0
