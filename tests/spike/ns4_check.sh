#!/bin/sh
# tests/spike/ns4_check.sh -- runs NS4 (mojito-sys #128, memory half).
#
# NS4 proves double release is impossible BY CONSTRUCTION: this script
# expects tests/spike/ns4_copy_is_compile_error.mojo to FAIL TO COMPILE
# with the specific ImplicitlyCopyable diagnostic. A clean compile, or a
# failure for any OTHER reason, is a FAIL for this driver.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
BINDING_DIR="$REPO_ROOT/spike/stack_switch"
SRC="$SCRIPT_DIR/ns4_copy_is_compile_error.mojo"
OUT_BIN="$REPO_ROOT/build/ns_tests/ns4_should_not_exist"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "ns4 FAIL (toolchain unavailable)"
    exit 2
fi

mkdir -p "$(dirname "$OUT_BIN")"
rm -f "$OUT_BIN"

out=$("$MOJO" build -I "$BINDING_DIR" "$SRC" -o "$OUT_BIN" 2>&1)
status=$?

if [ "$status" -eq 0 ] || [ -x "$OUT_BIN" ]; then
    echo "ns4 FAIL: NativeStack copy compiled successfully -- double release"
    echo "  is NOT prevented by construction. Build output:"
    printf '%s\n' "$out" | sed 's/^/    | /'
    rm -f "$OUT_BIN"
    exit 1
fi

if printf '%s' "$out" | grep -q "cannot be implicitly copied"; then
    echo "ns4 PASS: implicit copy of NativeStack is a compile error"
    printf '%s\n' "$out" | grep "cannot be implicitly copied" | sed 's/^/    | /'
    exit 0
fi

echo "ns4 FAIL: build failed, but NOT with the expected diagnostic"
echo "  ('cannot be implicitly copied'). Build output:"
printf '%s\n' "$out" | sed 's/^/    | /'
exit 1
