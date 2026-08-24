#!/bin/sh
# mojito-sys S1 — page-size / allocation-granularity query (issue #28).
#
# Runs page.mojo against libmojito_sys.dylib under the repo-root package
# layout (mojito_sys/memory/page.mojo + the frozen native page ABI). Prints
# a PASS/FAIL matrix and exits nonzero on any failure.
#
# This suite is TDD-red until mjs_granularity lands: the s1/build stub
# exports only mjs_page_size, so page.mojo fails to link against the stub
# dylib. The real sysconf-based mjs_granularity in native/posix/mjs_page.c
# (this lane) turns the suite green.
#
# Usage: tests/s1/memory/page/run.sh     (or: make test-s1 from repo root)
#   MOJO=/path/to/mojo overrides the compiler.
#
# Expects libmojito_sys.dylib to be built (make test-s1 builds it first).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
DYLIB="$REPO_ROOT/libmojito_sys.dylib"

TEST_FILE="$SCRIPT_DIR/page_conformance.mojo"
TEST_NAME="memory-page"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found; run \`make test-s1\` at the repo root first."
    echo "$TEST_NAME RUN-ERROR (library not built)"
    exit 2
fi

out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$DYLIB" "$TEST_FILE" 2>&1)
status=$?

matrix=""
echo "== $TEST_NAME"
# Always show the full output: failure diagnostics live in the matrix lines.
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    matrix="$TEST_NAME PASS
"
else
    matrix="$TEST_NAME FAIL
"
fi

echo ""
echo "S1 memory page-size conformance matrix (issue #28)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ "$matrix" = "$TEST_NAME FAIL
" ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
