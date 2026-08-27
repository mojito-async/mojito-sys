#!/bin/sh
# mojito-sys S5.7 — ctx stack-growth policy acceptance suite (issue #70).
#
# Runs stack_probe.c against the PACKAGED libmojito_sys.dylib at BOTH -O0
# and -O2, proving the FIXED-reservation, NO-automatic-growth policy:
#   - a deep call chain WELL INSIDE the reservation completes normally
#     (legitimate depth is never throttled);
#   - a saved sp forged OUTSIDE the reservation is rejected loudly
#     (SIGTRAP in a forked child) at switch/restore;
#   - a degenerately in-reservation sp (forged to the LOW boundary) is
#     also rejected loudly;
#   - reservation bounds are honored across repeated switches (a context
#     that grows/shrinks genuine live depth each resume round-trips
#     cleanly).
#
# Usage: tests/s5/ctx/stack/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s5-ctx-stack"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "== $TEST_NAME: SKIP-FAIL — compiler '$CC' not found"
    exit 1
fi
if [ ! -f "$DYLIB" ]; then
    echo "== $TEST_NAME: SKIP-FAIL — $DYLIB missing; run make first"
    exit 1
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #70)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/stack_probe_$opt"
    if ! "$CC" "-$opt" -Wall -Wextra -I"$REPO_ROOT/native/include" \
            "$SCRIPT_DIR/stack_probe.c" "$DYLIB" -o "$bin"; then
        matrix="$matrix$opt BUILD-FAIL
"
        failures=$((failures + 1))
        continue
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" 2>&1)
    st=$?
    printf '%s\n' "$out" | sed 's/^/   | /'
    if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        matrix="$matrix$opt PASS
"
    else
        matrix="$matrix$opt FAIL
"
        failures=$((failures + 1))
    fi
done

echo ""
echo "S5 ctx stack-growth policy matrix (issue #70)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0