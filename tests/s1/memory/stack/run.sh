#!/bin/sh
# mojito-sys S1 — memory/stack conformance harness (issue #30).
#
# Builds the stack_test Mojo driver together with its C probe
# (s1_stack_probe.c, linked into the same executable) and runs it against
# the packaged libmojito_sys.dylib from the repo root.
#
# The driver forks a child in C (probe) for the guard-region proof:
# a deliberate write into the PROT_NONE guard page must raise a synchronous
# hardware fault (SIGBUS on macOS arm64, SIGSEGV elsewhere) without touching
# the parent. Growth uses the frozen mjs_vm_commit service; until the vm
# lane lands, the dylib lacks it and this suite reports RED/FAIL — the
# expected TDD-red state (issues #29/#30).
#
# Usage: tests/s1/memory/stack/run.sh
#   MOJO=/path/to/mojo overrides the compiler. CC=<cc> overrides cc.
#
# Exit codes: 0 all green, 1 FAIL/RED, 2 prerequisite missing.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s1-memory-stack"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s1_memory_stack"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME FAIL (toolchain unavailable)"
    exit 2
fi
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: $CC not found; set CC=<compiler>"
    echo "$TEST_NAME FAIL (compiler unavailable)"
    exit 2
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #30)"

# Probe object: pure C, dlopens libmojito_sys.dylib at runtime, so a missing
# implementation yields a deterministic RED verdict, not a load failure.
if ! "$CC" -c "$SCRIPT_DIR/s1_stack_probe.c" -o "$OUT/s1_stack_probe.o"; then
    echo "$TEST_NAME RED (probe build failed)"
    exit 1
fi

if ! "$MOJO" build "$SCRIPT_DIR/stack_test.mojo" -o "$OUT/stack_test" \
    -I "$REPO_ROOT" -Xlinker "$OUT/s1_stack_probe.o" \
    2>"$OUT/stack_test.build.log"; then
    echo "$TEST_NAME RED (driver build failed - package scaffold/build lane not merged yet)"
    tail -n 8 "$OUT/stack_test.build.log" | sed 's/^/    | /'
    exit 1
fi

out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/stack_test" 2>&1)
st=$?
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    echo ""
    echo "S1 memory/stack matrix (issue #30)"
    echo "  $TEST_NAME PASS"
    echo "RESULT: all green"
    exit 0
fi
echo ""
echo "S1 memory/stack matrix (issue #30)"
echo "  $TEST_NAME RED (TDD: expected until build/vm lanes merge - issues #24/#29)"
echo "RESULT: red (TDD)"
exit 1