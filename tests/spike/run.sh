#!/bin/sh
# mojito-sys S0 spike — semantic test harness (tests-a lane, issue #11).
#
# Runs T1-T7 (spec section 6.5) with the mojo toolchain and prints a
# PASS/FAIL matrix. Exits nonzero if any test fails or prerequisites are
# missing.
#
# Usage: tests/spike/run.sh          (or: make test from the repo root)
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
BINDING_DIR="$REPO_ROOT/spike/context_switch"
DYLIB="$REPO_ROOT/libmojito_spike.dylib"

TESTS="t1_address_stability t2_borrowed_refs t3_destructor_exactness t4_raise_after_resume t5_raise_before_yield_cleanup t6_repeated_switching t7_nested_depth"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found; run \`make\` at the repo root first."
    for t in $TESTS; do
        echo "$t FAIL (library not built)"
    done
    exit 2
fi

failures=0
matrix=""
for t in $TESTS; do
    file="$SCRIPT_DIR/$t.mojo"
    out=$("$MOJO" run -Xlinker "$DYLIB" -I "$BINDING_DIR" "$file" 2>&1)
    status=$?
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "PASS"; then
        row="$t PASS"
    else
        row="$t FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    echo "== $t"
    # Show the tail of the output (failure diagnostics live at the end).
    printf '%s\n' "$out" | tail -n 6 | sed 's/^/   | /'
done

echo ""
echo "S0 spike semantic test matrix (issue #11)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/7 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
