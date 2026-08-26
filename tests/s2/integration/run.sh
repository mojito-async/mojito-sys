#!/bin/sh
# mojito-sys S2.9 — §41 EXIT-CRITERION integration lane (issue #56).
#
# Runs tests/s2/integration/worker_farm.mojo: N workers spawned via the public
# mojito_sys.thread surface, per-worker bindings in ONE NativeTlsKey retrieved
# across a synthetic context switch (spike pair), clean joins — zero private
# runtime APIs / module-level globals.
#
# Builds BOTH dylibs first: libmojito_sys.dylib (frozen mjs_* ABI) and
# libmojito_spike.dylib (synthetic context-switch pair), then runs under the
# repo-root package layout, mirroring tests/s2/thread/run_tls.sh.
#
# Usage: tests/s2/integration/run.sh   MOJO=/path/to/mojo (optional)
#   Expects to be run from a checkout where `make` works at the repo root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/worker_farm.mojo"
TEST_NAME="s2-integration-worker-farm"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild both dylibs so this suite always exercises current sources.
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

matrix=""
echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    matrix="$TEST_NAME PASS
"
else
    matrix="$TEST_NAME FAIL
"
fi

echo ""
echo "S2 integration (§41 exit criterion) matrix (issue #56)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ $status -ne 0 ] || ! printf '%s' "$out" | grep -q "RESULT: all green"; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
