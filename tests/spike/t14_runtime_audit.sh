#!/bin/sh
# t14_runtime_audit.sh — S0-T14: Mojo runtime-independence audit (spec 6.5).
#
# Owner: tests lane B (issue #12). Verifies that the spike's compiled
# artifact libmojito_spike.dylib references NO private Modular/Mojo
# async/coroutine/compiler-runtime symbols, per spec constraint "no private
# Mojo async/coroutine/runtime symbols" and CONTRACT.md "public Mojo
# facilities only above the C ABI".
#
# Method:
#   1. Locate the dylib ($MOJITO_SPIKE_DYLIB overrides; else common paths).
#   2. `nm -uU` its undefined symbols; every symbol must be either a system
#      library symbol or a public mojito_spike/ms_* symbol.
#   3. `nm -gU --defined-only` its exported symbols; nothing private may be
#      exported either.
#   4. Any symbol matching a private-runtime pattern (_MLIR/__mlir/__modart/
#      modart/asyncRT/AsyncRT/async_rt/__mojo/_mojo/kgen/coroutine) is a FAIL,
#      whether referenced or defined.
#
# Exit codes: 0 pass | 1 forbidden symbols found | 2 RED: dylib absent |
#             3 tooling error.
set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
lib="${MOJITO_SPIKE_DYLIB:-}"
if [ -z "$lib" ]; then
    for cand in \
        "$repo/spike/context_switch/libmojito_spike.dylib" \
        "$repo/libmojito_spike.dylib" \
        "$repo/build/libmojito_spike.dylib"; do
        if [ -f "$cand" ]; then
            lib="$cand"
            break
        fi
    done
fi

if [ -z "${lib:-}" ] || [ ! -f "$lib" ]; then
    echo "T14 RED: libmojito_spike.dylib not found — spike implementation absent (issues #8/#9)."
    echo "T14 RED: build it first (make in spike/context_switch/) or set MOJITO_SPIKE_DYLIB."
    exit 2
fi

echo "T14: auditing $lib"

command -v nm >/dev/null 2>&1 || { echo "T14 ERROR: nm not available"; exit 3; }

undef=$(nm -uU "$lib" 2>/dev/null) || { echo "T14 ERROR: nm -uU failed"; exit 3; }
defined=$(nm -gU --defined-only "$lib" 2>/dev/null) || { echo "T14 ERROR: nm failed on defined symbols"; exit 3; }

# Symbols the spike is allowed to import: libc/libSystem/pthread/mach/dyld
# surface plus its own public ABI.
allow='^_(ms_|mach_|pthread|os_|dispatch|malloc|free|calloc|realloc|posix_memalign|mem[a-z]*$|str[a-z]*$|bzero|bcmp|close|open|read|write|mmap|munmap|mprotect|madvise|msync|mincore|sysconf|getpagesize|exit|abort|__stack_chk_|___stack_chk_|dyld|_dyld|objc|swift|kCF|CF[A-Z]|NS[a-z])'

private='_MLIR|__mlir|[Mm][Ll][Ii][Rr]|modart|[Aa]sync[Rr][Tt]|asyncrt|__mojo|_mojo|kgen|[Kk]gen|[Cc]oroutine|COROUTINE'


# Extract bare symbol names from both lists and screen them.
check_list() {
    _list="$1"
    _kind="$2"
    printf '%s\n' "$_list" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[A-Za-z_$][A-Za-z0-9_$]*$/) print $i }' | sort -u | while IFS= read -r sym; do
        [ "$sym" = "_" ] && continue
        if ! printf '%s' "$sym" | grep -Eq "$allow"; then
            if printf '%s' "$sym" | grep -Eq "$private"; then
                echo "FORBIDDEN[$_kind] $sym"
            fi
        fi
    done
}

violations="$( { check_list "$undef" undefined; check_list "$defined" defined; } )"

if [ -n "$violations" ]; then
    echo "T14 FAIL: private Mojo/Modular runtime symbols detected:"
    printf '%s\n' "$violations"
    exit 1
fi

echo "T14 PASS: no private Mojo async/coroutine/runtime symbols referenced or exported."
exit 0
