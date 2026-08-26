#!/bin/sh
# mojito-sys S2.7 — §38.5 THREAD conformance runner (issue #54).
#
# Per-lane runner invoked by the canonical tests/s2/conformance/run.sh
# aggregator; TEST_NAME matches the gate's known-red key family.
#
# AOT-builds threads/conformance.mojo against libmojito_sys.dylib (the JIT
# deterministically SIGSEGVs lowering this wrapper mix, precedent
# tests/s2/thread/run_thread.sh) and runs it. Prints '<name> PASS/FAIL'
# plus a RESULT line:
#     RESULT: all green | RESULT: FAILED
#
# Usage: tests/s2/conformance/threads/run.sh   MOJO=/path/to/mojo

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s2-conformance-threads"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources.
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: run_thread.sh); retry a
# bounded number of times, keeping the last output.
BIN="$BUILD_DIR/s27_threads_conformance"
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" build -I "$REPO_ROOT" \
        -Xlinker "$REPO_ROOT/libmojito_sys.dylib" \
        -o "$BIN" "$TEST_FILE" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
        out=$(env DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN" 2>&1)
        status=$?
    fi
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2  # compiler crash: retry
    fi
done

echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

matrix=""
if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    matrix="$TEST_NAME PASS
"
else
    matrix="$TEST_NAME FAIL
"
fi

echo ""
echo "S2.7 thread conformance matrix (issue #54)"
printf '%s' "$matrix" | sed 's/^/  /'
case "$matrix" in
    *"FAIL"*)
        echo "RESULT: FAILED"
        exit 1
        ;;
esac
echo "RESULT: all green"
exit 0
