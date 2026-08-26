#!/bin/sh
# mojito-sys S5 — ctx behavioral probe suite (issue #64, panel F6).
#
# Committed regression net for the frozen ms_context v2 ABI: the
# sentinel probe (sentinel_probe.c) runs init/capture/switch/yields/
# exit round-trips against the PACKAGED libmojito_sys.dylib and verifies
# x19-x28 + d8-d15 preservation plus 16-byte sp alignment at -O0 AND
# -O2, then checks argument validation (-EINVAL), the
# capture-revives-destroyed contract, and the loud SIGTRAP on resume of
# a destroyed context (fork-isolated).
#
# Usage: tests/s5/ctx/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s5_ctx_sentinel"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: CC=$CC not found"
    echo "$TEST_NAME FAIL (compiler unavailable)"
    exit 2
fi
if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found; run \`make\` at the repo root first."
    echo "$TEST_NAME FAIL (dylib missing)"
    exit 2
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #64 F6)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/sentinel_probe_$opt"
    if ! "$CC" -$opt -Wall -Wextra -I"$REPO_ROOT/native/include" \
            "$SCRIPT_DIR/sentinel_probe.c" "$DYLIB" -o "$bin"; then
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
echo "S5 ctx sentinel matrix (issue #64 F6)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
