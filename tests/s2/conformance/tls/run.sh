#!/bin/sh
# mojito-sys S2.7 — §38.5 TLS conformance runner (issue #54).
#
# Per-lane runner invoked by the canonical tests/s2/conformance/run.sh
# aggregator. Runs tls/conformance.mojo against libmojito_sys.dylib AND
# libmojito_spike.dylib (synthetic context-switch pair reused for the
# §38.5 switch-continuity check), mirroring tests/s2/thread/run_tls.sh.
# Prints '<name> PASS/FAIL' plus a RESULT line:
#     RESULT: all green | RESULT: FAILED
#
# Usage: tests/s2/conformance/tls/run.sh   MOJO=/path/to/mojo

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s2-conformance-tls"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild both dylibs so this suite always exercises the current
# sources (mjs_tls.c via wildcard; spike ctx pair for the continuity leg).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib libmojito_spike.dylib \
        >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make dylibs failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s2/thread/run_tls.sh);
# retry a bounded number of times, keeping the last output.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" run -I "$REPO_ROOT" \
        -I "$REPO_ROOT/spike/context_switch" \
        -Xlinker "$REPO_ROOT/libmojito_sys.dylib" \
        -Xlinker "$REPO_ROOT/libmojito_spike.dylib" \
        "$TEST_FILE" 2>&1)
    status=$?
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2 # compiler crash: retry
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
echo "S2.7 TLS conformance matrix (issue #54)"
printf '%s' "$matrix" | sed 's/^/  /'
case "$matrix" in
    *"FAIL"*)
        echo "RESULT: FAILED"
        exit 1
        ;;
esac
echo "RESULT: all green"
exit 0
