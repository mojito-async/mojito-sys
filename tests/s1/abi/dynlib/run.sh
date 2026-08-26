#!/bin/sh
# mojito-sys S1.13 — abi/dynlib conformance (mojito-sys #46).
#
# Runs the S1.13 dynamic-library conformance test under the repo-root
# package layout (mojito_sys/abi/dynlib.mojo). Pure Mojo — no native dylib
# needed (the main image provides the resolved symbols). Prints a PASS/FAIL
# matrix and exits nonzero on any failure.
#
# Usage: tests/s1/abi/dynlib/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s1-dynlib"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

out=$("$MOJO" run -I "$REPO_ROOT" "$TEST_FILE" 2>&1)
status=$?

echo "== $TEST_NAME"
# Always show the full output: failure diagnostics live in the matrix lines.
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    echo ""
    echo "S1.13 ABI dynlib conformance matrix (issue #46)"
    echo "  $TEST_NAME PASS"
    echo "RESULT: all green"
    exit 0
fi

# D12 — batch-review H2: the raw-handle constructor path is GONE. Compiling
# `DynamicLibrary(<int>)` must FAIL (open_library()/main_library() are the
# sole construction paths; unsafe_takeownership is module-internal).
PROBE_DIR=$(mktemp -d)
trap 'rm -rf "$PROBE_DIR"' EXIT
cat > "$PROBE_DIR/d12_probe.mojo" <<'EOF'
from mojito_sys.abi.dynlib import DynamicLibrary


def main():
    var lib = DynamicLibrary(1234)
    _ = lib
EOF
d12="D12 raw-int ctor blocked"
probe_out=$("$MOJO" run -I "$REPO_ROOT" "$PROBE_DIR/d12_probe.mojo" 2>&1)
if [ $? -ne 0 ]; then
    echo "PASS: $d12"
else
    echo "FAIL: $d12 (raw-handle constructor still compiles)"
    printf '%s\n' "$probe_out" | sed 's/^/   | /'
    exit 1
fi

echo ""
echo "S1.13 ABI dynlib conformance matrix (issue #46)"
echo "  $TEST_NAME FAIL"
echo "RESULT: FAILED"
exit 1
