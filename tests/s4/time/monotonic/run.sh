#!/bin/sh
# mojito-sys S4 — monotonic-clock conformance lane (issue #63).
#
# Runs the §38.9 time conformance (conformance.mojo) against the packaged
# libmojito_sys.dylib under the repo-root package layout:
#   - ≥20k monotonic reads; progress; duration_since identities;
#   - saturation boundaries + ~100y mocked intervals;
#   - conversion round-trips; resolution sanity;
#   - cross-check vs test-local libc CLOCK_MONOTONIC_RAW (ratio 0.9–1.1,
#     median-of-3 over 50–100ms windows);
#   - NULL-out -EFAULT; calibration-once 1M-call smoke.
#
# Builds the dylib first (the Makefile picks up native/posix/*.c by
# wildcard, so no Makefile edit is needed for this lane's sources).
#
# Usage: tests/s4/time/monotonic/run.sh     MOJO=/path/to/mojo CC=<cc>
#   Expects to be run from a checkout where `make` works at the repo root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="time-monotonic"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_time.c included).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s1/memory/vm/run.sh);
# retry a bounded number of times, keeping the last output.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$TEST_FILE" 2>&1)
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
echo "S4 time monotonic conformance matrix (issue #63)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ "$matrix" = "$TEST_NAME FAIL
" ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
