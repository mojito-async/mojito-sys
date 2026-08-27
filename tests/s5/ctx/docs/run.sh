#!/bin/sh
# mojito-sys S5.8 — ctx debug/unwind + platform-notes documentation lane
# (issue #71). Conformance name: s5-ctx-docs.
#
# The DOC is this lane's deliverable; the fixture is a probe that makes the
# documentation testable in TDD order:
#   - doc_probe.c asserts the documented claims COMPILE and HOLD against the
#     packaged libmojito_sys.dylib: the "Context debug/unwind + platform
#     notes" spec section (documents the markers doc_probe.c checks), the
#     lifecycle traps observable via SIGTRAP on misuse (brk #0x66/#0x68/
#     #0x69 in fork children), the documented state-machine transitions
#     (EMPTY -> RUNNING -> SUSPENDED -> RUNNING -> FINISHED, capture-REVIVE),
#     and loud -EINVAL rejection of an unaligned synthetic stack.
# The probe is RED while the spec section is absent and GREEN once it lands.
#
# Usage: tests/s5/ctx/docs/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
SPEC="$REPO_ROOT/docs/mojito-sys_IMPLEMENTATION_SPEC.md"
TEST_NAME="s5-ctx-docs"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "== $TEST_NAME: SKIP-FAIL — compiler '$CC' not found"
    exit 1
fi
if [ ! -f "$DYLIB" ]; then
    echo "== $TEST_NAME: SKIP-FAIL — $DYLIB missing; run make first"
    exit 1
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #71)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/docs_probe_$opt"
    if ! "$CC" "-$opt" -Wall -Wextra -pthread -I"$REPO_ROOT/native/include" \
            "$SCRIPT_DIR/doc_probe.c" "$DYLIB" -o "$bin"; then
        matrix="$matrix$opt BUILD-FAIL
"
        failures=$((failures + 1))
        continue
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" "$SPEC" 2>&1)
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
echo "S5 ctx docs matrix (issue #71)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0