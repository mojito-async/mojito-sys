#!/bin/sh
# mojito-sys S5.3 — ctx lifecycle acceptance suite (issue #66).
#
# Runs lifecycle_probe.c against the PACKAGED libmojito_sys.dylib at
# BOTH -O0 and -O2, proving:
#   - >64 simultaneous live contexts (global return-to table deleted);
#   - >=4 threads running independent sustained switch pairs;
#   - completion hook fires exactly once per finished context;
#   - re-resume of FINISHED and RUNNING contexts traps loudly (SIGTRAP);
#   - misaligned synthetic stack rejected loudly (-EINVAL, no crash).
#
# Usage: tests/s5/ctx/lifecycle/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s5_ctx_lifecycle"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "== $TEST_NAME: SKIP-FAIL — compiler '$CC' not found"
    exit 1
fi
if [ ! -f "$DYLIB" ]; then
    echo "== $TEST_NAME: SKIP-FAIL — $DYLIB missing; run make first"
    exit 1
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #66)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/lifecycle_probe_$opt"
    if ! "$CC" "-$opt" -Wall -Wextra -pthread -I"$REPO_ROOT/native/include" \
            "$SCRIPT_DIR/lifecycle_probe.c" "$DYLIB" -o "$bin"; then
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
echo "S5 ctx lifecycle matrix (issue #66)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
