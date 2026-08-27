#!/bin/sh
# mojito-sys S5.9 — x86-64 System V ctx backend (issue #72, spec §21 #2).
#
# Cross-target backend lane for the frozen ms_context v2/v3 ABI. This host
# is Darwin/arm64, so the x86-64 SysV backend CANNOT execute here; the lane
# therefore mirrors the ELF-row precedent (tests/s5/ctx/run.sh §4):
#   - an assemble-only smoke PROVES the x86-64 SysV code assembles, via
#     cc --target=x86_64-apple-macosx (clang on Apple Silicon
#     cross-assembles x86-64), plus a symbol-surface check on the object;
#   - behavioral rows are parametrized by platform: they run ONLY on a
#     native Linux/x86_64 host; elsewhere they print an explicit
#     UNSUPPORTED-PLATFORM row (red-excluded per spec §38.6 — "a platform
#     is not NativeContext-supported until this suite passes" — never a
#     silent skip).
#
# Usage: tests/s5/x86/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-x86"
ASM="$REPO_ROOT/native/posix/ms_context_x86_64.S"
TEST_NAME="s5-ctx-x86"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: CC=$CC not found"
    echo "$TEST_NAME FAIL (compiler unavailable)"
    exit 2
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #72, spec §21 #2 x86-64 System V)"

failures=0
rows=""

# ---- assemble smoke -------------------------------------------------------
# Cross-assemble the x86-64 SysV backend on any host whose cc targets
# x86_64 (clang on Apple Silicon can cross-assemble x86-64 Mach-O).
# This is the REQUIRED proof that the backend is structurally sound even
# where it cannot execute (mirrors the ELF-skeleton assemble smoke).
if [ ! -f "$ASM" ]; then
    # Implementation absent => RED (TDD): the lane must fail until the
    # backend is added, so the pre-commit gate sees an intentional red.
    echo "   | x86-assemble FAIL: $ASM not present (feature not implemented)"
    rows="$rows x86-assemble FAIL (implementation absent)
"
    failures=$((failures + 1))
elif "$CC" --target=x86_64-apple-macosx \
        -c "$ASM" -o "$OUT/ms_context_x86_64.o" 2>"$OUT/x86_asm.err"; then
    echo "   | x86-assemble: x86-64 SysV backend cross-assembles cleanly"
    rows="$rows x86-assemble PASS
"
    # Symbol-surface check: the object must expose the public switch
    # entry point and the dylib-private make_raw/trampoline primitives
    # (internal; nothing new goes into exports.txt).
    if command -v nm >/dev/null 2>&1; then
        syms=$(nm "$OUT/ms_context_x86_64.o" 2>/dev/null | \
            awk '{print $3}' | grep -E \
            'ms_context_switch|mjs__ctx_make_raw|mjs_ctx_trampoline')
        if [ -n "$syms" ] && \
                printf '%s\n' "$syms" | grep -q ms_context_switch && \
                printf '%s\n' "$syms" | grep -q mjs__ctx_make_raw && \
                printf '%s\n' "$syms" | grep -q mjs_ctx_trampoline; then
            rows="$rows x86-symbols PASS
"
        else
            echo "   | x86-symbols FAIL: expected switch/make_raw/trampoline symbol not found:"
            printf '%s\n' "$syms" | sed 's/^/   |   /'
            rows="$rows x86-symbols FAIL
"
            failures=$((failures + 1))
        fi
    else
        echo "   | x86-symbols SKIP (nm unavailable)"
        rows="$rows x86-symbols SKIP (no nm)
"
    fi
else
    # Assembler rejected the tree: distinguish whether the toolchain simply
    # cannot cross-assemble (SKIP) from a real assembly error (FAIL).
    if "$CC" --target=x86_64-apple-macosx -c /dev/null \
            -o "$OUT/_probe.o" 2>/dev/null; then
        echo "   | x86-assemble FAIL (cross-assembler error):"
        printf '%s\n' "$OUT/x86_asm.err" | sed 's/^/   |     /'
        rows="$rows x86-assemble FAIL
"
        failures=$((failures + 1))
    else
        echo "   | x86-assemble SKIP (cross-assembler unavailable):"
        printf '%s\n' "$OUT/x86_asm.err" | sed 's/^/   |     /'
        rows="$rows x86-assemble SKIP (no cross-assembler)
"
    fi
fi

# ---- 2. Behavioral x86-64 backend rows (parametrized; §38.6 explicit) ----
# The full §23 minimum harness on the x86-64 backend (sentinel round-trip,
# capture, finish hook, loud traps; see tests/s5/ctx/lifecycle) is driven
# ONLY on a Linux/x86_64 native host. Darwin/arm64 backends — exactly
# like the arm64 ELF half before it — are explicit RED-EXCLUDED.
platform="$(uname -s)/$(uname -m)"
case "$platform" in
Linux/x86_64|Linux/x64)
    # Native path: build a shared lib from all native sources, then drive
    # the sentinel probe against it (cross-ABI smoke of the full surface).
    so="$OUT/libmojito_sys_x86.so"
    if "$CC" -O2 -g -fPIC -I"$REPO_ROOT/native/include" -shared \
            "$REPO_ROOT"/native/posix/*.c "$REPO_ROOT"/native/posix/*.S \
            -o "$so"; then
        bins_ok=1
        for opt in O0 O2; do
            bin="$OUT/sentinel_probe_x86_$opt"
            if ! "$CC" "-$opt" -Wall -Wextra -I"$REPO_ROOT/native/include" \
                    "$REPO_ROOT/tests/s5/ctx/sentinel_probe.c" "$so" \
                    -o "$bin"; then
                bins_ok=0
                continue
            fi
            out=$(LD_LIBRARY_PATH="$OUT" "$bin" 2>&1)
            if [ $? -ne 0 ] || ! printf '%s' "$out" |
                    grep -q "RESULT: all green"; then
                bins_ok=0
                printf '%s\n' "$out" | sed 's/^/   | /'
            fi
        done
        if [ $bins_ok -eq 1 ]; then
            rows="$rows x86-backend PASS
"
        else
            rows="$rows x86-backend FAIL
"
            failures=$((failures + 1))
        fi
    else
        echo "   | x86-backend FAIL: x86-64 shared-object build failed"
        rows="$rows x86-backend FAIL
"
        failures=$((failures + 1))
    fi
    ;;
*)
    echo "   | x86-backend UNSUPPORTED-PLATFORM ($platform): behavioral"
    echo "   |   rows are red-excluded per spec §38.6 until a Linux/x86-64"
    echo "   |   runner exists (explicit exclusion, NOT a silent skip)"
    rows="$rows x86-backend RED-EXCLUDED ($platform, §38.6)
"
    ;;
esac

echo ""
echo "S5.9 x86-64 SysV backend matrix (issue #72)"
echo "$rows" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0