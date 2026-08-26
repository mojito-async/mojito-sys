#!/bin/sh
# mojito-sys S1 — ABI — callback token conformance harness (issues #32, #43).
#
# Two halves, one process (tests/s1/memory/stack lane pattern):
#   1. nullity pin — a literal `unsafe_from_address=0` must stay a compile
#      error (b2 non-nullable UnsafePointer; CallbackToken.unset() is the
#      only supported null-construction path);
#   2. conformance driver — driver.c is compiled ad hoc (NOT part of
#      libmojito_sys; no new exported symbols) and linked into the
#      AOT-built conformance_test executable via -Xlinker. The C half pins
#      the frozen mjs_callback_token layout as compile-time asserts and
#      invokes INTO Mojo's @export abi("C") callback through the token;
#      Mojo asserts the sentinel arrived (issue #43).
#
# Prints a PASS/FAIL matrix and RESULT line; exits nonzero on failure or
# missing prerequisites.
#
# Portability: cc flags are uname-derived (no -arch flag); the dylib path
# is anchored at REPO_ROOT with the suffix chosen from uname -s.
#
# Usage: tests/s1/abi/callbacks/run.sh
#   MOJO=/path/to/mojo CC=/path/to/cc override the toolchain.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
OUT="$SCRIPT_DIR/.build"

case "$(uname -s)" in
    Darwin)
        SOEXT=dylib
        LD_ENV=DYLD_LIBRARY_PATH
        ;;
    *)
        SOEXT=so
        LD_ENV=LD_LIBRARY_PATH
        ;;
esac
DYLIB="$REPO_ROOT/libmojito_sys.$SOEXT"

TEST_NAME="s1_abi_callbacks"
DRIVER="$OUT/driver.o"
BIN="$OUT/conformance_test"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME FAIL (toolchain unavailable)"
    exit 2
fi
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: $CC not found; set CC=<compiler>"
    echo "$TEST_NAME FAIL (toolchain unavailable)"
    exit 2
fi

# The package scaffold (mojito_sys/__init__.mojo, mojito_sys/abi/__init__.mojo)
# is owned by the S1Build lane and lands in its PR. Until it merges, this
# suite stays red (expected TDD-red); the guard makes the cause explicit
# instead of a silent "cannot resolve package" import error.
if [ ! -d "$REPO_ROOT/mojito_sys" ]; then
    echo "ERROR: $REPO_ROOT/mojito_sys missing; S1Build package scaffold not merged yet."
    echo "$TEST_NAME FAIL (package scaffold absent)"
    exit 1
fi

mkdir -p "$OUT"

failures=0
matrix=""

echo "== $TEST_NAME (issues #32/#43)"

# --- 1. H2 pin (issue #32): b2's UnsafePointer is non-nullable ---------------
pin=$(mktemp "${TMPDIR:-/tmp}/mjs_null_pin.XXXXXX.mojo")
trap 'rm -f "$pin"' EXIT
cat > "$pin" <<'EOF'
from mojito_sys.abi.callbacks import VoidPtr


def main():
    var p = VoidPtr(unsafe_from_address=0)
EOF
if "$MOJO" run -I "$REPO_ROOT" "$pin" >/dev/null 2>&1; then
    echo "ERROR: nullability contract broken: literal unsafe_from_address=0 compiled"
    matrix="${matrix}nullability-pin FAIL
"
    failures=$((failures + 1))
else
    matrix="${matrix}nullability-pin PASS
"
fi

# --- 2. Native half: ad hoc object, frozen-layout static asserts live here ---
# Host-toolchain flags only: no -arch, target follows uname-derived host.
if ! "$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
        -c "$SCRIPT_DIR/driver.c" -o "$DRIVER" 2>"$OUT/driver.build.log"; then
    echo "driver-build FAIL"
    tail -n 8 "$OUT/driver.build.log" | sed 's/^/    | /'
    matrix="${matrix}driver-build FAIL
"
    echo ""
    echo "S1 abi/callbacks conformance matrix (issues #32/#43)"
    printf '%s' "$matrix" | sed 's/^/  /'
    echo "RESULT: 1 FAILED"
    exit 1
fi
matrix="${matrix}driver-build PASS
"

# --- 3. Mojo half AOT-built against the driver object ------------------------
# The packaged dylib is linked when present so the executable also pins its
# load shape; the callbacks module itself imports no mjs_* symbol, so its
# absence is not an error for this suite.
LINK_ARGS=""
if [ -f "$DYLIB" ]; then
    LINK_ARGS="-Xlinker $DYLIB"
fi
if ! "$MOJO" build "$SCRIPT_DIR/conformance_test.mojo" -o "$BIN" \
        -I "$REPO_ROOT" \
        -Xlinker "$DRIVER" $LINK_ARGS \
        2>"$OUT/conformance_test.build.log"; then
    echo "conformance-test RED (driver build failed)"
    tail -n 8 "$OUT/conformance_test.build.log" | sed 's/^/    | /'
    matrix="${matrix}conformance-test FAIL
"
    failures=$((failures + 1))
else
    out=$(env "$LD_ENV=$REPO_ROOT" "$BIN" 2>&1)
    st=$?
    printf '%s\n' "$out" | sed 's/^/   | /'
    if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        matrix="${matrix}conformance-test PASS
"
    else
        matrix="${matrix}conformance-test FAIL
"
        failures=$((failures + 1))
    fi
fi

echo ""
echo "S1 abi/callbacks conformance matrix (issues #32/#43)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
