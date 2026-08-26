#!/bin/sh
# mojito pre-commit gate — runs locally before every commit.
#
# Tier 0: structural validators.                   Always run; block on failure.
# Tier 1: full test suite (selftest, T1-T7, T8-T14, bench). Failures block the
#         commit UNLESS the test is allow-listed in precommit/known-red.tsv as
#         an intentional TDD-red test with a tracking issue.
#
# Env:
#   MOJITO_GATE_FAST=1  skip the slow suite (T8-T14 builds + bench).
#   MOJO=</path/to/mojo> override the Mojo toolchain (default: mojo on PATH).
#
# Host rules (same as claude/OX agents on this host):
#   - This gate NEVER deletes or modifies anything outside the workspace; it
#     only builds inside the repo and runs the project's own test suites.
#   - No staged rename/delete outside workspace/ can pass through this gate;
#     it is a peer of the AGENTS.md rules, not a replacement.
set -u

cd "$(git rev-parse --show-toplevel)" || exit 2

GATE_DIR="$PWD/precommit"
KNOWN_RED="$GATE_DIR/known-red.tsv"
FAST="${MOJITO_GATE_FAST:-0}"
failures=0

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- Tier 0 ----
# 0.1 whitespace / trailing-whitespace errors in the staged diff
ws_errors=$(git diff --cached --check 2>&1)
if [ -n "$ws_errors" ]; then
    say "Tier 0 FAIL: whitespace errors in staged diff:"
    printf '%s\n' "$ws_errors" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

# 0.2 build artifacts / junk must never be staged
blocked=$(git diff --cached --name-only \
    | grep -E '(^|/)(build|\.build)/|\.(dylib|o|a|pyc|class|tmp|swp)$|\.DS_Store' || true)
if [ -n "$blocked" ]; then
    say "Tier 0 FAIL: build artifacts / junk must not be committed:"
    printf '%s\n' "$blocked" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

# 0.3 unresolved merge conflict markers in staged content
conflicts=$(git grep --cached -n -E '^(<<<<<<< |>>>>>>> )' -- \
    '*.mojo' '*.c' '*.S' '*.h' '*.sh' '*.md' 2>/dev/null || true)
if [ -n "$conflicts" ]; then
    say "Tier 0 FAIL: unresolved conflict markers in staged content:"
    printf '%s\n' "$conflicts" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------- Tier 1 ----
run_check() { # <name> <command...>
    name=$1
    shift
    out=$("$@" 2>&1)
    st=$?
    if [ "$st" -eq 0 ]; then
        printf '%-38s PASS\n' "$name"
    elif grep -q "^$name	" "$KNOWN_RED"; then
        printf '%-38s RED (known-red, TDD)\n' "$name"
        printf '%s\n' "$out" | tail -n 4 | sed 's/^/    | /'
    else
        printf '%-38s FAIL\n' "$name"
        printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'
        failures=$((failures + 1))
    fi
}

if ! command -v "${MOJO:-mojo}" >/dev/null 2>&1; then
    say "Tier 1 FAIL: ${MOJO:-mojo} not on PATH; set MOJO=<path-to-mojo>"
    failures=$((failures + 1))
else
    if [ "$FAST" != "1" ]; then
        say "== full suite (selftest, T1-T14, bench) — fast=$FAST"
        run_check selftest   make selftest
        run_check t1-t7      make test
        run_check t8-t14     ./tests/spike/run_t8_t14.sh
        run_check bench      make bench
        run_check s1-tests         make test-s1
        run_check s2-tests         make test-s2
        run_check s2-conformance   make test-s2-conformance
        run_check s2-stress        make test-s2-stress
        run_check s2-integration   make test-s2-integration
        run_check s2-pkg           make test-s2-pkg
        run_check s3-tests         make test-s3
        run_check s5-tests         make test-s5
        run_check no-markers  sh -c "! git grep -n -E '^(<<<<<<< |>>>>>>> )' -- native mojito_sys tests benchmark"
    else
        say "== fast suite (selftest, T1-T7) — fast=1"
        run_check selftest   make selftest
        run_check t1-t7      make test
        run_check s1-tests         make test-s1
        run_check s2-tests         make test-s2
        run_check s2-conformance   make test-s2-conformance
        run_check s2-stress        make test-s2-stress
        run_check s2-integration   make test-s2-integration
        run_check s2-pkg           make test-s2-pkg
        run_check s3-tests         make test-s3
        run_check s5-tests         make test-s5
        run_check no-markers  sh -c "! git grep -n -E '^(<<<<<<< |>>>>>>> )' -- native mojito_sys tests benchmark"
    fi
fi

# ---------------------------------------------------------------- summary ----
if [ "$failures" -ne 0 ]; then
    say ""
    say "GATE FAILED ($failures issue(s))."
    say "  - Unexpected test failure? Fix the code. After the change the"
    say "    commit may proceed."
    say "  - Intentional TDD red? Add the test name to precommit/known-red.tsv"
    say "    with its tracking issue, and remove the row when it goes green."
    say "  - Emergency escape hatch: git commit --no-verify (see"
    say "    precommit/README.md for why this should stay rare)."
    exit 1
fi
say "gate: all checks passed"
exit 0