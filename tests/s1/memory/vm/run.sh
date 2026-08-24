#!/bin/sh
# mojito-sys S1.7 — memory/vm conformance runner (issue #29).
#
# Builds this lane's native object (native/posix/mjs_vm.c) into a local
# dylib, then runs tests/s1/memory/vm/vm_test.mojo against the mojito_sys
# package via `mojo run -I <repo-root> -Xlinker <dylib>`.
#
# Requires:
#   - mojo on PATH (override with MOJO=)
#   - cc on PATH
#   - the mojito_sys package scaffold (mojito_sys/__init__.mojo and
#     mojito_sys/memory/__init__.mojo) — owned by the S1.1 build lane, plus
#     native/include/mojito_sys.h (frozen C ABI). Until those land in the
#     shared tree the runner reports RED (expected TDD-red).
#
# Prints a PASS/FAIL matrix and exits nonzero if the test fails.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../../" && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}

BUILD_DIR="$SCRIPT_DIR/.build"
TEST_FILE="$SCRIPT_DIR/vm_test.mojo"
DYLIB="$BUILD_DIR/libmojito_sys_vm.dylib"
TESTS="vm"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

failures=0
matrix=""
for t in $TESTS; do
    # Build the lane dylib from this lane's C source (no Makefile change).
    mkdir -p "$BUILD_DIR"
    if ! "$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
         -c "$REPO_ROOT/native/posix/mjs_vm.c" -o "$BUILD_DIR/mjs_vm.o" 2>"$BUILD_DIR/cc.err"; then
        echo "== $t"
        echo "   | mjs_vm.c build failed (native/posix/mjs_vm.c or frozen header missing); TDD-red"
        echo "$t FAIL"
        echo ""
        echo "S1.7 memory/vm matrix (issue #29)"
        echo "  $t FAIL"
        echo "RESULT: 1/1 FAILED"
        exit 1
    fi
    if ! "$CC" -dynamiclib -o "$DYLIB" "$BUILD_DIR/mjs_vm.o" 2>"$BUILD_DIR/ld.err"; then
        echo "== $t"
        echo "   | dylib link failed; TDD red"
        echo "$t FAIL"
        echo ""
        echo "S1.7 memory/vm matrix (issue #29)"
        echo "  $t FAIL"
        echo "RESULT: 1/1 FAILED"
        exit 1
    fi

    # The b2 toolchain intermittently segfaults while lowering
    # stack_allocation-heavy modules (see issue #29 notes); retry a bounded
    # number of times, keeping the last output.
    status=2
    out=""
    attempt=0
    while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$DYLIB" "$TEST_FILE" 2>&1)
        status=$?
        if printf '%s' "$out" | grep -q "Stack dump"; then
            status=2  # compiler crash: retry
        fi
    done

    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT:.*PASSED"; then
        row="$t PASS"
    else
        row="$t FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    echo "== $t"
    printf '%s\n' "$out" | tail -n 8 | sed 's/^/   | /'
done

echo ""
echo "S1.7 memory/vm conformance matrix (issue #29)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/1 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
