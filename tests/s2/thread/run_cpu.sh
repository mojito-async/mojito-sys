#!/bin/sh
# mojito-sys S2 — cpu Mojo wrapper conformance driver (issue #53).
#
# Builds libmojito_sys.dylib at the repo root, captures the HOST truth for
# CPU topology (the same oracle tests/s2/native/cpu_smoke.c asserts against:
# sysctl hw.logicalcpu/hw.physicalcpu on darwin, getconf _NPROCESSORS_ONLN
# on Linux), and runs the §13 conformance suite in cpu_test.mojo against the
# packaged dylib. Prints '<suite-name> PASS/FAIL' plus a RESULT line:
#     RESULT: all green
#
# Usage: tests/s2/thread/run.sh    MOJO=/path/to/mojo optional.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/cpu_test.mojo"
TEST_NAME="s2-cpu-mojo"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# Host topology truth -> environment for the suite. Physical core count has
# no portable Linux query (the C layer walks /sys itself); an empty value
# means "no host oracle", and the suite skips that cross-check.
HOST_OS=$(uname -s)
case "$HOST_OS" in
    Darwin)
        MOJITO_HOST_OS=darwin
        MOJITO_HOST_LOGICAL=$(sysctl -n hw.logicalcpu 2>/dev/null || true)
        MOJITO_HOST_PHYSICAL=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
        ;;
    Linux)
        MOJITO_HOST_OS=linux
        MOJITO_HOST_LOGICAL=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)
        MOJITO_HOST_PHYSICAL=
        ;;
    *)
        MOJITO_HOST_OS=unknown
        MOJITO_HOST_LOGICAL=
        MOJITO_HOST_PHYSICAL=
        ;;
esac
export MOJITO_HOST_OS MOJITO_HOST_LOGICAL MOJITO_HOST_PHYSICAL

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s4/time/monotonic);
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

echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

echo ""
echo "S2 thread cpu wrapper matrix (issue #53)"
if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    echo "  $TEST_NAME PASS"
    echo ""
    echo "RESULT: all green"
    exit 0
fi
echo "  $TEST_NAME FAIL"
echo ""
echo "RESULT: FAILED"
exit 1
