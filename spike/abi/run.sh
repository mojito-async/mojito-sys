#!/bin/sh
# spike/abi/run.sh — M1.2 (#124) ABI spike runner: struct-layout half,
# libc-call half, and the leaf-module-constraint probe.
#
# Builds spike/abi/oracle.c into a local dylib (ad hoc, no Makefile
# change — same convention as tests/s1/memory/vm/run.sh), then runs each
# Mojo test file against it via `mojo run -I <repo-root>/spike/abi
# -Xlinker <dylib>` (ordinary_frame_test.mojo needs no dylib — every
# symbol it touches is raw libc/OS, no oracle indirection at all).
#
# Usage: spike/abi/run.sh          (or: from the repo root)
#   MOJO=/path/to/mojo   override the Mojo toolchain
#   CC=<cc>              override the C compiler
#
# Prints a PASS/FAIL matrix and exits nonzero if any lane fails.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BUILD_DIR="$SCRIPT_DIR/.build"
DYLIB="$BUILD_DIR/liboracle.dylib"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "RESULT: 1 FAILED"
    exit 2
fi

mkdir -p "$BUILD_DIR"
if ! "$CC" -O2 -g -Wall -Wextra -dynamiclib -o "$DYLIB" \
     "$SCRIPT_DIR/oracle.c" 2>"$BUILD_DIR/cc.err"; then
    echo "spike/abi: oracle.c build failed:"
    sed 's/^/  | /' "$BUILD_DIR/cc.err"
    echo "RESULT: 1 FAILED"
    exit 2
fi

failures=0
matrix=""

# run_lane <name> <file> <needs-dylib: 0|1>
run_lane() {
    name=$1
    file=$2
    needs_dylib=$3

    status=2
    out=""
    attempt=0
    # The b2 toolchain intermittently segfaults while lowering modules
    # (precedent: tests/s1/memory/vm/run.sh, spike/completion/run.sh);
    # retry a bounded number of times, keeping the last output.
    while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        if [ "$needs_dylib" = "1" ]; then
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" -Xlinker "$DYLIB" "$file" 2>&1)
        else
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" "$file" 2>&1)
        fi
        status=$?
        if printf '%s' "$out" | grep -q "Stack dump"; then
            status=2 # compiler crash: retry
        fi
    done

    echo "== $name"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/   | /'

    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        matrix="$matrix$name PASS
"
    else
        matrix="$matrix$name FAIL
"
        failures=$((failures + 1))
    fi
    echo ""
}

run_lane "struct-layout"    "struct_layout_test.mojo"   1
run_lane "libc-calls"       "libc_calls_test.mojo"      1
run_lane "ordinary-frame"   "ordinary_frame_test.mojo"  0

echo "M1.2 abi spike matrix (issue #124)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
