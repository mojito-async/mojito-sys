#!/bin/sh
# benchmark/ctx/run.sh — mojito-sys S5.6 permanent switch benchmark + same-host
# regression gate (issue #69).
#
# Self-contained lane (does NOT touch Makefile / precommit/gate.sh; the
# S6.7 bench lane owns those edits and will wire `run_check s5-ctx-bench
# benchmark/ctx/run.sh`):
#   1. builds the packaged libmojito_sys.dylib if missing;
#   2. AOT-compiles benchmark/ctx/bench_switch.mojo against it
#      (mojo build -Xlinker <dylib>; AOT not `mojo run` — the b2 JIT
#      deterministically traps the production #66 context lifecycle on this
#      host, see the bench's module docstring);
#   3. runs the bench on THIS host, capturing the machine-parseable
#      BENCH_RESULT rows;
#   4. applies benchmark/ctx/gate.sh: compares switch_latency_ns and
#      round_trips_per_sec against the committed benchmark/ctx/baselines.tsv
#      with a generous (b2-flake-calibrated) tolerance; exits non-zero on a
#      genuine regression or a missing/unparseable baseline;
#   5. ends with `RESULT: all green` on success.
#
# Usage: benchmark/ctx/run.sh
#   MOJO=<path-to-mojo> overrides the toolchain.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
OUT="$REPO_ROOT/build/s5-ctx-bench"
BIN="$OUT/bench_switch"
RESULTS="$OUT/results.tsv"
BASELINES="$SCRIPT_DIR/baselines.tsv"
TEST_NAME="s5-ctx-bench"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: MOJO=$MOJO not found on PATH"
    echo "$TEST_NAME FAIL (mojo unavailable)"
    exit 2
fi
if [ ! -f "$DYLIB" ]; then
    echo "== $TEST_NAME: building packaged dylib ($DYLIB)"
    if ! make -C "$REPO_ROOT" libmojito_sys.dylib >/dev/null 2>&1; then
        echo "ERROR: failed to build $DYLIB via make"
        echo "$TEST_NAME FAIL (dylib build failed)"
        exit 2
    fi
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #69)"

failures=0
matrix=""

# ---- 2. AOT-compile the bench -------------------------------------------
if ! "$MOJO" build "$SCRIPT_DIR/bench_switch.mojo" \
        -Xlinker "$DYLIB" -o "$BIN" 2>"$OUT/build.err"; then
    echo "   | bench BUILD-FAIL:"
    sed 's/^/   |   /' "$OUT/build.err"
    echo "RESULT: bench build failed"
    exit 1
fi
matrix="$matrix bench-build PASS
"

# ---- 3. run on this host, capture BENCH_RESULT rows ---------------------
if ! DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN" >"$OUT/bench.out" 2>"$OUT/bench.err"; then
    echo "   | bench RUN-FAIL:"
    tail -n 20 "$OUT/bench.err" | sed 's/^/   |   /'
    tail -n 20 "$OUT/bench.out" | sed 's/^/   |   /'
    echo "RESULT: bench run failed"
    exit 1
fi
printf '%s\n' "---- raw bench output ----"
sed 's/^/   | /' "$OUT/bench.out"
printf '%s\n' "---------------------------"

# machine-parseable rows (see the .mojo tail).
switch_ns=$(grep '^BENCH_RESULT switch_latency_ns=' "$OUT/bench.out" \
    | sed 's/.*= *//')
rps=$(grep '^BENCH_RESULT round_trips_per_sec=' "$OUT/bench.out" \
    | sed 's/.*= *//')
check=$(grep '^BENCH_RESULT register_check=' "$OUT/bench.out" \
    | sed 's/.*= *//')

if [ -z "$switch_ns" ] || [ -z "$rps" ]; then
    echo "   | FAIL: no BENCH_RESULT rows found in bench output"
    echo "RESULT: bench output parse failed"
    exit 1
fi
if [ "$check" != "pass" ]; then
    echo "   | FAIL: register_check=$check (fiber/scheduler counter mismatch)"
    echo "RESULT: register check failed"
    exit 1
fi
matrix="$matrix bench-run PASS (switch=${switch_ns}ns rps=${rps})"
matrix="$matrix
"

printf '%s\n' "$switch_ns" >"$OUT/switch_ns"
printf '%s\n' "$rps" >"$OUT/rps"

# ---- 4. same-host regression gate ----------------------------------------
gate_out=$(SCTX_SWITCH_NS="$switch_ns" SCTX_RPS="$rps" \
    sh "$SCRIPT_DIR/gate.sh" "$OUT" 2>&1)
gate_st=$?
printf '%s\n' "$gate_out" | sed 's/^/   | /'
if [ $gate_st -eq 0 ] && printf '%s' "$gate_out" | grep -q "GATE: PASS"; then
    matrix="$matrix gate PASS
"
else
    matrix="$matrix gate FAIL
"
    failures=$((failures + 1))
fi

echo ""
echo "S5.6 ctx bench matrix (issue #69)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0