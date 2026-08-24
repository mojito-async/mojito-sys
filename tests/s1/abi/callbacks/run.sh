#!/bin/sh
# mojito-sys S1 — ABI — callback token conformance harness (issue #32).
#
# Runs the callback-token conformance test and prints a PASS/FAIL matrix.
# Exits nonzero on failure or missing prerequisites.
#
# The package scaffold (mojito_sys/__init__.mojo, mojito_sys/abi/__init__.mojo)
# is owned by the S1Build lane; until that lane merges, this suite reports
# FAIL (unresolvable import) even though callbacks.mojo is present. That is
# the expected TDD-red state: the build lane landing makes it green.
#
# Usage: tests/s1/abi/callbacks/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
MOJO=${MOJO:-mojo}

TESTS="conformance_test"

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
    file="$SCRIPT_DIR/$t.mojo"
    out=$("$MOJO" run -I "$REPO_ROOT" "$file" 2>&1)
    status=$?
    # A passing run prints a PASS line; compilation/import failure reports FAIL.
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "PASS"; then
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
echo "S1 abi/callbacks conformance matrix (issue #32)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/1 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0