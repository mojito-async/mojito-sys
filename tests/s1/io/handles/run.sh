#!/bin/sh
# mojito-sys S6.1 — io scaffold: NativeIoHandle suite (issue #73).
#
# Runs tests/s1/io/handles/handles_test.mojo against the platform libc
# (no mojito dylib).  Prints a PASS/FAIL matrix and exits nonzero on any
# failure.
#
# Usage: tests/s1/io/handles/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
PKG_ROOT="$REPO_ROOT"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    exit 2
fi

out=$("$MOJO" run -I "$PKG_ROOT" "$SCRIPT_DIR/handles_test.mojo" 2>&1)
status=$?

echo ""
echo "S6.1 io native-io-handle matrix (issue #73):"

# The test emits its own t1..t3 + RESULT rows; echo them verbatim.
printf '%s\n' "$out" | grep -E '^(t[0-9]_|RESULT)' | sed 's/^/  /'

if printf '%s' "$out" | grep -q 'RESULT: all green'; then
    echo "RESULT: all green"
    exit 0
fi
if printf '%s' "$out" | grep -q 'FAIL'; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: toolchain error (exit=$status)"
printf '%s\n' "$out" | tail -n 12 | sed 's/^/  | /'
exit 1
