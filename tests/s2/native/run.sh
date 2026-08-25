#!/bin/sh
# mojito-sys S2.1 — native thread conformance runner (issue #48).
#
# Builds native/posix/mjs_thread.c into a lane dylib (mirroring the
# tests/s1/memory/vm/run.sh pattern), then compiles and runs the pure-C
# acceptance smoke tests/s2/native/thread_smoke.c against it.
#
# TDD: until mjs_thread.c + the header block land, the build step fails and
# this runner reports RED (expected; see precommit/known-red.tsv row
# 's2-thread').
#
# Usage: tests/s2/native/run.sh   CC=/path/to/cc (optional)
#
# Contract lines consumed by suite drivers:
#   print "RESULT: all green"  on success
#   print "RESULT: <n> FAILED" on any failure

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}

BUILD_DIR="$SCRIPT_DIR/.build"
DYLIB="$BUILD_DIR/libmojito_sys_thread.dylib"
TESTS="thread"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: CC=$CC not found"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

failures=0
matrix=""
for t in $TESTS; do
    mkdir -p "$BUILD_DIR"

    # Build the lane dylib from this lane's C source (no Makefile change).
    if ! "$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
         -c "$REPO_ROOT/native/posix/mjs_thread.c" \
         -o "$BUILD_DIR/mjs_thread.o" 2>"$BUILD_DIR/cc.err"; then
        echo "== $t"
        echo "   | mjs_thread.c build failed (native/posix/mjs_thread.c or"
        echo "   | frozen-header thread block missing); TDD-red"
        echo "$t FAIL"
        echo ""
        echo "S2.1 native/thread matrix (issue #48)"
        echo "  $t FAIL"
        echo "RESULT: 1/1 FAILED"
        exit 1
    fi

    LDFLAGS=""
    # Linux-portable: pthreads live in libpthread there; harmless on darwin.
    if [ "$(uname -s)" != "Darwin" ]; then
        LDFLAGS="-lpthread"
    fi
    if ! "$CC" -dynamiclib -o "$DYLIB" "$BUILD_DIR/mjs_thread.o" \
         $LDFLAGS 2>"$BUILD_DIR/ld.err"; then
        echo "== $t"
        echo "   | dylib link failed; TDD red"
        echo "$t FAIL"
        echo ""
        echo "S2.1 native/thread matrix (issue #48)"
        echo "  $t FAIL"
        echo "RESULT: 1/1 FAILED"
        exit 1
    fi

    out=$("$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
          "$SCRIPT_DIR/thread_smoke.c" "$DYLIB" $LDFLAGS \
          -o "$BUILD_DIR/thread_smoke" 2>&1)
    if [ $? -ne 0 ]; then
        status=1
        echo "== $t"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/   | /'
    else
        out=$(env DYLD_LIBRARY_PATH="$BUILD_DIR" LD_LIBRARY_PATH="$BUILD_DIR" \
              "$BUILD_DIR/thread_smoke" 2>&1)
        status=$?
        echo "== $t"
        printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/   | /'
    fi

    if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all PASSED"; then
        row="$t PASS"
    else
        row="$t FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
done

echo ""
echo "S2.1 native/thread conformance matrix (issue #48)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/1 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
