#!/bin/sh
# mojito-sys S0/M1.4 spike -- semantic test harness (tests-a lane, issue #11;
# re-pointed for #128).
#
# Runs T1-T7 (spec section 6.5) against the PRODUCTION
# native/posix/ms_context_aarch64.S `ms_context_switch`, called directly
# (spike/stack_switch/ctx_direct.mojo), on a
# spike/stack_switch/native_stack.mojo NativeStack -- not the S0 spike's own
# throwaway spike/context_switch/aarch64_switch.S. Prints a PASS/FAIL matrix;
# exits nonzero if any test fails or prerequisites are missing.
#
# AOT, NOT `mojo run`: the b2 JIT deterministically traps the production v3
# context lifecycle's first switch (benchmark/ctx/run.sh documents this
# first; confirmed independently again while re-pointing these tests). Every
# test here is built with `mojo build` and the resulting binary executed
# directly.
#
# RETRY ON A KNOWN, FILED, FLAKY COMPILER CRASH (mojito-sys#202): a raise
# propagating through several ordinary Mojo frames while a live NativeStack
# sits on an ancestor frame intermittently (not deterministically) crashes
# `mojo build` itself, unrelated to whether the test's own logic is
# correct. A build that crashes with the signature that issue documents is
# retried a bounded number of times before this driver calls it a real
# failure, mirroring how this repo already treats `bench`'s own flaky
# libKGENCompilerRTShared crash (precommit/known-red.tsv).
#
# Usage: tests/spike/run.sh          (or: make test from the repo root)
#   MOJO=/path/to/mojo overrides the compiler.
#   CC=/path/to/cc overrides the C compiler for the two linked objects.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BINDING_DIR="$REPO_ROOT/spike/stack_switch"
OUT="$REPO_ROOT/build/ctx_tests"
MAX_BUILD_ATTEMPTS=3

TESTS="t1_address_stability t2_borrowed_refs t3_destructor_exactness t4_raise_after_resume t5_raise_before_yield_cleanup t6_repeated_switching t7_nested_depth"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

mkdir -p "$OUT"

if ! "$CC" -arch arm64 -O2 -I "$REPO_ROOT/native/include" -c "$REPO_ROOT/native/posix/ms_context.c" -o "$OUT/ms_context.o" 2>"$OUT/ms_context.err"; then
    echo "ERROR: failed to build native/posix/ms_context.c:"
    sed 's/^/  /' "$OUT/ms_context.err"
    exit 2
fi
if ! "$CC" -arch arm64 -c "$REPO_ROOT/native/posix/ms_context_aarch64.S" -o "$OUT/ms_context_aarch64.o" 2>"$OUT/ms_context_aarch64.err"; then
    echo "ERROR: failed to build native/posix/ms_context_aarch64.S:"
    sed 's/^/  /' "$OUT/ms_context_aarch64.err"
    exit 2
fi

failures=0
matrix=""
for t in $TESTS; do
    file="$SCRIPT_DIR/$t.mojo"
    bin="$OUT/$t"
    attempt=1
    build_ok=0
    while [ "$attempt" -le "$MAX_BUILD_ATTEMPTS" ]; do
        build_out=$("$MOJO" build -I "$BINDING_DIR" \
            -Xlinker "$OUT/ms_context.o" -Xlinker "$OUT/ms_context_aarch64.o" \
            "$file" -o "$bin" 2>&1)
        if [ $? -eq 0 ]; then
            build_ok=1
            break
        fi
        if printf '%s' "$build_out" | grep -q "Please submit a bug report"; then
            # mojito-sys#202: flaky compiler crash, retry.
            attempt=$((attempt + 1))
            continue
        fi
        break
    done

    if [ "$build_ok" -ne 1 ]; then
        row="$t FAIL (build)"
        failures=$((failures + 1))
        matrix="$matrix$row
"
        echo "== $t: BUILD FAIL after $attempt attempt(s)"
        printf '%s\n' "$build_out" | tail -n 15 | sed 's/^/   | /'
        continue
    fi

    out=$("$bin" 2>&1)
    status=$?
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "PASS"; then
        row="$t PASS"
    else
        row="$t FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    echo "== $t"
    printf '%s\n' "$out" | tail -n 6 | sed 's/^/   | /'
done

echo ""
echo "S0/M1.4 spike semantic test matrix (issues #11, #128)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/7 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
