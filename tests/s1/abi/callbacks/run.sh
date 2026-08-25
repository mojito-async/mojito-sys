#!/bin/sh
# mojito-sys S1 — ABI — callback token conformance harness (issue #32).
#
# Runs the callback-token conformance test and prints a PASS/FAIL matrix.
# Exits nonzero on failure or missing prerequisites.
#
# Usage: tests/s1/abi/callbacks/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}

TESTS="conformance_test"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    for t in $TESTS; do
        echo "$t FAIL (toolchain unavailable)"
    done
    exit 2
fi

# The package scaffold (mojito_sys/__init__.mojo, mojito_sys/abi/__init__.mojo)
# is owned by the S1Build lane and lands in its PR. Until it merges, this
# suite stays red (expected TDD-red); the guard makes the cause explicit
# instead of a silent "cannot resolve package" import error.
if [ ! -d "$REPO_ROOT/mojito_sys" ]; then
    echo "ERROR: $REPO_ROOT/mojito_sys missing; S1Build package scaffold not merged yet."
    for t in $TESTS; do
        echo "$t FAIL (package scaffold absent)"
    done
    exit 1
fi

failures=0
matrix=""

# H2 pin (issue #32): b2's UnsafePointer is non-nullable — a literal
# `unsafe_from_address=0` MUST stay a compile error. CallbackToken.unset()
# is the only supported null-construction path; this fails fast if a
# future toolchain ever accepts the literal, silently reopening a second
# null path beside the factory.
pin=$(mktemp "${TMPDIR:-/tmp}/mjs_null_pin.XXXXXX.mojo")
trap 'rm -f "$pin"' EXIT
cat > "$pin" <<'EOF'
from mojito_sys.abi.callbacks import VoidPtr


def main():
    var p = VoidPtr(unsafe_from_address=0)
EOF
if "$MOJO" run -I "$REPO_ROOT" "$pin" >/dev/null 2>&1; then
    echo "ERROR: nullability contract broken: literal unsafe_from_address=0 compiled"
    for t in $TESTS; do
        echo "$t FAIL (nullability pin)"
    done
    exit 3
fi
for t in $TESTS; do
    file="$SCRIPT_DIR/$t.mojo"
    out=$("$MOJO" run -I "$REPO_ROOT" "$file" 2>&1)
    status=$?
    # A passing run prints a PASS line; compilation/import failure reports FAIL.
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "PASS"; then
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
echo "S1 abi/callbacks conformance matrix (issue #32)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures/1 FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
