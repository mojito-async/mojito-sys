#!/bin/sh
# mojito-sys S1.2 — abi/types conformance runner (issue #25).
#
# Runs tests/s1/abi/types/conformance.mojo against the mojito_sys package
# via `mojo run -I <repo-root>`.
#
# Requires:
#   - mojo on PATH (override with MOJO=)
#   - the mojito_sys package scaffold (mojito_sys/__init__.mojo and
#     mojito_sys/abi/__init__.mojo) present — owned by the S1.1 build
#     lane. Until that lands, this runner reports RED (expected TDD).
#
# Prints a PASS/FAIL matrix and exits nonzero if the test fails.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../../" && pwd)
MOJO=${MOJO:-mojo}

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TESTS="conformance"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

failures=0
matrix=""
for t in $TESTS; do
    out=$("$MOJO" run -I "$REPO_ROOT" "$TEST_FILE" 2>&1)
    status=$?
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT:.*PASSED"; then
        row="$t PASS"
    else
        row="$t FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    echo "== $t"
    printf '%s\n' "$out" | tail -n 8 | sed 's/^/   | /'
done

echo ""
echo "S1.2 abi/types conformance matrix (issue #25)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/1 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0