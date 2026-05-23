#!/usr/bin/env bash
# test-hooks.sh
#
# Exercises each hook with simulated Claude Code payloads and checks the exit codes.
# Run this after editing any hook. Run it in CI.
#
# Hooks read a JSON payload on stdin and exit 0 (allow) or 2 (block).

set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

check() {
    local name="$1"; shift
    local expected="$1"; shift
    local actual="$1"; shift
    if [ "$actual" = "$expected" ]; then
        echo "  ✅ $name (exit $actual)"
        PASS=$((PASS+1))
    else
        echo "  ❌ $name (expected $expected, got $actual)"
        FAIL=$((FAIL+1))
    fi
}

echo "── pre-sql-execute.sh ────────────────────────────────────────────────"

# Case 1: harmless SELECT — should pass
payload='{"tool_input": {"command": "duckdb warehouse.duckdb -c \"select count(*) from events_daily\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "harmless SELECT allowed" 0 $?

# Case 2: DROP TABLE — should block
payload='{"tool_input": {"command": "duckdb warehouse.duckdb -c \"DROP TABLE events_daily\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "DROP TABLE blocked" 2 $?

# Case 3: TRUNCATE — should block
payload='{"tool_input": {"command": "psql -c \"truncate table customers\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "TRUNCATE blocked" 2 $?

# Case 4: DELETE without WHERE — should block
payload='{"tool_input": {"command": "duckdb -c \"delete from orders;\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "DELETE without WHERE blocked" 2 $?

# Case 5: DELETE with WHERE — should pass
payload='{"tool_input": {"command": "duckdb -c \"delete from orders where status = '\''test'\''\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "DELETE with WHERE allowed" 0 $?

# Case 6: DROP with override token — should pass
payload='{"tool_input": {"command": "-- I_HAVE_BACKED_UP\nDROP TABLE old_table"}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "DROP with I_HAVE_BACKED_UP allowed" 0 $?

# Case 7: ALTER ... DROP COLUMN — should block
payload='{"tool_input": {"command": "duckdb -c \"alter table users drop column email\""}}'
echo "$payload" | .claude/hooks/pre-sql-execute.sh >/dev/null 2>&1
check "ALTER DROP COLUMN blocked" 2 $?

echo ""
echo "── pii-check.sh ──────────────────────────────────────────────────────"

# Case 1: staging model with raw email — should block
payload='{"path": "dbt_project/models/staging/stg_users.sql", "content": "select id, email, created_at from raw"}'
echo "$payload" | .claude/hooks/pii-check.sh >/dev/null 2>&1
check "raw email in staging blocked" 2 $?

# Case 2: staging model with hashed email — should pass
payload='{"path": "dbt_project/models/staging/stg_users.sql", "content": "select id, md5(lower(trim(email))) as email_hash, created_at from raw"}'
echo "$payload" | .claude/hooks/pii-check.sh >/dev/null 2>&1
check "hashed email in staging allowed" 0 $?

# Case 3: mart model with raw email — should pass (only staging is enforced)
payload='{"path": "dbt_project/models/marts/users_daily.sql", "content": "select email, count(*) from raw group by 1"}'
echo "$payload" | .claude/hooks/pii-check.sh >/dev/null 2>&1
check "mart not subject to staging PII check" 0 $?

# Case 4: non-SQL file — should pass
payload='{"path": "scripts/run.py", "content": "email = config[\"email\"]"}'
echo "$payload" | .claude/hooks/pii-check.sh >/dev/null 2>&1
check "non-staging-SQL file ignored" 0 $?

# Case 5: phone column unhashed — should block
payload='{"path": "dbt_project/models/staging/stg_contacts.sql", "content": "select id, phone from raw"}'
echo "$payload" | .claude/hooks/pii-check.sh >/dev/null 2>&1
check "raw phone in staging blocked" 2 $?

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
