#!/bin/sh
# mojito-sys S1.3 — SysError/ErrorDomain conformance (mojito-sys #26).
#
# Runs the S1.3 ABI error-conformance test under the repo-root package
# layout (mojito_sys/abi/errors.mojo). Pure Mojo — no native dylib needed.
# Prints a PASS/FAIL matrix and exits nonzero on any failure.
#
# Usage: tests/s1/abi/errors/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s1-abi-errors"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

out=$("$MOJO" run -I "$REPO_ROOT" "$TEST_FILE" 2>&1)
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
echo "S1.3 ABI error conformance matrix (issue #26)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ "$matrix" = "$TEST_NAME FAIL
" ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0