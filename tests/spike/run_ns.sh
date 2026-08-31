#!/bin/sh
# tests/spike/run_ns.sh -- NativeStack acceptance suite (mojito-sys #128,
# memory half). Builds spike/stack_switch/*.c oracles + the AOT test
# drivers, runs NS1-NS5, and prints a PASS/FAIL matrix.
#
# Usage: tests/spike/run_ns.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BINDING_DIR="$REPO_ROOT/spike/stack_switch"
OUT="$REPO_ROOT/build/ns_tests"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "ns-suite FAIL (toolchain unavailable)"
    exit 2
fi

mkdir -p "$OUT"

# ---- C oracles --------------------------------------------------------
if ! "$CC" -arch arm64 -O2 -Wall -Wextra -c "$BINDING_DIR/mapping_probe.c" -o "$OUT/mapping_probe.o" 2>"$OUT/mapping_probe.err"; then
    echo "ERROR: failed to build mapping_probe.c:"
    sed 's/^/  /' "$OUT/mapping_probe.err"
    exit 2
fi
if ! "$CC" -arch arm64 -O2 -Wall -Wextra -c "$BINDING_DIR/guard_fault_probe.c" -o "$OUT/guard_fault_probe.o" 2>"$OUT/guard_fault_probe.err"; then
    echo "ERROR: failed to build guard_fault_probe.c:"
    sed 's/^/  /' "$OUT/guard_fault_probe.err"
    exit 2
fi
if ! "$CC" -arch arm64 -O2 -I "$REPO_ROOT/native/include" -c "$REPO_ROOT/native/posix/mjs_stack.c" -o "$OUT/mjs_stack.o" 2>"$OUT/mjs_stack.err"; then
    echo "ERROR: failed to build the C oracle (native/posix/mjs_stack.c):"
    sed 's/^/  /' "$OUT/mjs_stack.err"
    exit 2
fi

failures=0
matrix=""

run_ns() { # <name> <mojo-file> [extra -Xlinker objs...]
    name=$1
    src="$SCRIPT_DIR/$2"
    shift 2
    xlinkers=""
    for o in "$@"; do
        xlinkers="$xlinkers -Xlinker $o"
    done
    bin="$OUT/$name"
    # shellcheck disable=SC2086
    if ! "$MOJO" build -I "$BINDING_DIR" $xlinkers "$src" -o "$bin" >"$OUT/$name.build.log" 2>&1; then
        echo "== $name: BUILD FAIL"
        tail -n 20 "$OUT/$name.build.log" | sed 's/^/   | /'
        matrix="$matrix$name FAIL (build)
"
        failures=$((failures + 1))
        return
    fi
    out=$("$bin" 2>&1)
    status=$?
    echo "== $name"
    printf '%s\n' "$out" | tail -n 10 | sed 's/^/   | /'
    if [ "$status" -eq 0 ]; then
        matrix="$matrix$name PASS
"
    else
        matrix="$matrix$name FAIL
"
        failures=$((failures + 1))
    fi
}

run_ns ns1 ns1_alloc_free_storm.mojo "$OUT/mapping_probe.o"
run_ns ns2 ns2_move_stability.mojo
run_ns ns3 ns3_guard_fault_and_c_oracle.mojo "$OUT/mjs_stack.o" "$OUT/guard_fault_probe.o"
run_ns ns5 ns5_dtor_exactly_once_on_raise.mojo "$OUT/mapping_probe.o"

# ns4 is a compile-FAIL test; its own script owns the verdict.
echo "== ns4"
if "$SCRIPT_DIR/ns4_check.sh" >"$OUT/ns4.log" 2>&1; then
    tail -n 5 "$OUT/ns4.log" | sed 's/^/   | /'
    matrix="${matrix}ns4 PASS
"
else
    tail -n 20 "$OUT/ns4.log" | sed 's/^/   | /'
    matrix="${matrix}ns4 FAIL
"
    failures=$((failures + 1))
fi

echo ""
echo "NativeStack acceptance matrix (issue #128, memory half)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
