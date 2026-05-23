#!/usr/bin/env bash
# scripts/verify.sh — single-command quality gate.
#
# Runs every check the project considers "done" (per CLAUDE.md). Designed to be
# the ONE place these checks live — pre-commit, CI, and the `quality-gate`
# Claude skill all call this script so they can't drift apart.
#
# Modes:
#   ./scripts/verify.sh           # default: fast static checks (lint, parse, hook tests)
#   ./scripts/verify.sh --full    # also runs dbt build + data_quality.py
#                                 # (requires a populated warehouse.duckdb)
#   ./scripts/verify.sh --json    # JSON-lines output for the quality-gate skill
#
# Exit codes:
#   0  all green
#   1  at least one check failed
#   64 bad arguments
#
# Each check is implemented as a function. They all run (we don't short-circuit
# on the first failure) so the developer sees every problem in one pass.

set -uo pipefail

FULL=0
JSON=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        --json) JSON=1 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Try --help" >&2
            exit 64
            ;;
    esac
done

# Repo root regardless of where the script was invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FAILED_CHECKS=()

emit() {
    # Two output modes: human-readable (default) or JSON lines (--json).
    local level="$1"; local check="$2"; local msg="$3"
    if [[ "$JSON" -eq 1 ]]; then
        printf '{"check":"%s","level":"%s","message":%s}\n' \
            "$check" "$level" "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    else
        case "$level" in
            pass) printf '  \033[32m✓\033[0m %-22s %s\n' "$check" "$msg" ;;
            fail) printf '  \033[31m✗\033[0m %-22s %s\n' "$check" "$msg" ;;
            skip) printf '  \033[33m·\033[0m %-22s %s\n' "$check" "$msg" ;;
            info) printf '    %-22s %s\n' "" "$msg" ;;
        esac
    fi
}

header() {
    [[ "$JSON" -eq 1 ]] && return
    printf '\n\033[1m%s\033[0m\n' "$1"
}

run_check() {
    # Wraps a check function. On non-zero exit, records the failure and prints any
    # captured output as an info line so the developer can see what went wrong.
    local name="$1"; shift
    local output exit_code
    output="$("$@" 2>&1)"
    exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        emit pass "$name" "ok"
    else
        emit fail "$name" "exit $exit_code"
        if [[ -n "$output" && "$JSON" -eq 0 ]]; then
            printf '%s\n' "$output" | sed 's/^/      /'
        fi
        FAILED_CHECKS+=("$name")
    fi
}

# ---------- individual checks ----------

check_ruff() {
    command -v ruff >/dev/null || { echo "ruff not installed"; return 127; }
    ruff check pipelines scripts
}

check_sqlfluff() {
    command -v sqlfluff >/dev/null || { echo "sqlfluff not installed"; return 127; }
    # Lint only — the post-write hook does the auto-fixing. Here we just want a verdict.
    sqlfluff lint dbt_project/models --dialect duckdb
}

check_dbt_parse() {
    command -v dbt >/dev/null || { echo "dbt not installed"; return 127; }
    (cd dbt_project && dbt parse --quiet)
}

check_test_hooks() {
    [[ -x scripts/test-hooks.sh ]] || { echo "scripts/test-hooks.sh missing or not executable"; return 1; }
    scripts/test-hooks.sh
}

check_dbt_build() {
    command -v dbt >/dev/null || { echo "dbt not installed"; return 127; }
    (cd dbt_project && dbt build --quiet)
}

check_data_quality() {
    [[ -f warehouse.duckdb ]] || { echo "no warehouse.duckdb — skipping"; return 99; }
    python3 scripts/data_quality.py
}

# ---------- driver ----------

header "Static checks"
run_check "ruff"          check_ruff
run_check "sqlfluff"      check_sqlfluff
run_check "dbt parse"     check_dbt_parse
run_check "hook self-tests" check_test_hooks

if [[ "$FULL" -eq 1 ]]; then
    header "Integration checks (--full)"
    run_check "dbt build"     check_dbt_build
    # data_quality returns 99 to signal "warehouse missing, skip" — treat as skip not fail.
    output="$(check_data_quality 2>&1)"
    rc=$?
    if [[ "$rc" -eq 99 ]]; then
        emit skip "data quality" "$output"
    elif [[ "$rc" -eq 0 ]]; then
        emit pass "data quality" "ok"
    else
        emit fail "data quality" "exit $rc"
        [[ -n "$output" && "$JSON" -eq 0 ]] && printf '%s\n' "$output" | sed 's/^/      /'
        FAILED_CHECKS+=("data quality")
    fi
else
    [[ "$JSON" -eq 0 ]] && printf '\n  (skipped: dbt build, data quality — pass --full to run them)\n'
fi

# ---------- verdict ----------

if [[ "$JSON" -eq 0 ]]; then
    echo
    if [[ "${#FAILED_CHECKS[@]}" -eq 0 ]]; then
        printf '\033[32mAll checks passed.\033[0m\n'
    else
        printf '\033[31m%d check(s) failed:\033[0m %s\n' \
            "${#FAILED_CHECKS[@]}" "${FAILED_CHECKS[*]}"
    fi
fi

[[ "${#FAILED_CHECKS[@]}" -eq 0 ]] && exit 0 || exit 1
