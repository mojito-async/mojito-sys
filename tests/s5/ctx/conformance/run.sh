#!/bin/sh
# mojito-sys S5.5 — ctx permanent T1..T14 conformance suite (issue #68).
#
# Promotes the S0 spike's T1..T14 semantics from a one-off feasibility spike
# into a PERMANENT regression net. Runs conformance_probe.c against the
# PACKAGED libmojito_sys.dylib at BOTH -O0 and -O2, proving (each as a C
# equivalent of spec §6.5 / §38.6, through the PUBLIC frozen ABI):
#   T1  local-address stability     T2  borrowed-reference validity
#   T3  destructor exactness        T4  error after resume
#   T5  error before yield+cleanup  T6  repeated switching (>=1,000,000)
#   T7  nested call depth (64)      T8  integer-register preservation
#   T9  SIMD/FP preservation        T10 stack alignment
#   T11 TLS continuity              T12 synthetic-stack entry/exit+reclaim
#   T13 guard-page behavior         T14 Mojo runtime independence (audit)
#
# TDD (issue #68): the RED commit carries T13 against a caller-provided RAW
# buffer with no guard page — the overflow silently writes adjacent memory
# and T13 correctly FAILS. The GREEN commit carves the T13 stack with
# mjs_stack_alloc (paints a PROT_NONE guard) so the overflow raises a
# controlled SIGBUS/SIGSEGV and T13 passes.
#
# Usage: tests/s5/ctx/conformance/run.sh   (CC=<cc> overrides)

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s5_ctx_conformance"

# Guarded-alloc T13 build flag: 0 (RED) = raw caller-provided buffer with no
# guard page; 1 = mjs_stack_alloc paints a real PROT_NONE guard page.
GUARDED=${CONFORMANCE_GUARDED:-0}

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "== $TEST_NAME: SKIP-FAIL — compiler '$CC' not found"
    exit 1
fi
if [ ! -f "$DYLIB" ]; then
    echo "== $TEST_NAME: SKIP-FAIL — $DYLIB missing; run make first"
    exit 1
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #68; T13 guarded=$GUARDED)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/conformance_probe_$opt"
    if ! "$CC" "-$opt" -Wall -Wextra -pthread -I"$REPO_ROOT/native/include" \
            -DT13_USE_GUARDED_ALLOC=$GUARDED \
            "$SCRIPT_DIR/conformance_probe.c" "$DYLIB" -o "$bin"; then
        matrix="$matrix$opt BUILD-FAIL
"
        failures=$((failures + 1))
        continue
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" 2>&1)
    st=$?
    printf '%s\n' "$out" | sed 's/^/   | /'
    if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        matrix="$matrix$opt PASS
"
    else
        matrix="$matrix$opt FAIL
"
        failures=$((failures + 1))
    fi
done

echo ""
echo "S5 ctx conformance matrix (issue #68)"
echo "$matrix" | sed 's/^/  /'

# ---- T14: Mojo runtime independence (non-vacuous symbol audit) ----------
echo ""
t14_out=$(sh "$SCRIPT_DIR/t14_runtime_audit.sh" 2>&1)
t14_st=$?
printf '%s\n' "$t14_out" | sed 's/^/  | /'
if [ $t14_st -eq 0 ]; then
    echo "  T14 runtime independence PASS"
else
    echo "  T14 runtime independence FAIL"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
