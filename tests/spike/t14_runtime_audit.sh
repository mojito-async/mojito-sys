#!/bin/sh
# t14_runtime_audit.sh — S0/M1.4-T14: Mojo runtime-independence audit
# (spec 6.5; issue #12; re-pointed for #128).
#
# RE-POINTED (#128): the S0 spike's own throwaway libmojito_spike.dylib is
# gone from this leg's switch half -- T8-T13 link the PRODUCTION
# native/posix/ms_context.c + ms_context_aarch64.S directly into each Mojo
# AOT binary (no dylib in the loop at all for them). The artifact worth
# auditing for "no private Mojo/Modular runtime symbols leaked" is
# therefore the production ms_context object pair itself: this script
# builds a small, single-purpose dylib from EXACTLY those two files (never
# linked against any Mojo runtime, so if this audit ever finds a private
# Mojo/Modular symbol here, that would be a genuinely alarming result, not
# a rebuild-and-retry flake) and audits that.
#
# This is DELIBERATELY narrower than auditing the full libmojito_sys.dylib
# (built by the repo-root Makefile from every native/*.c and native/*.S):
# that library also carries io_uring/epoll/socket/thread/sync code
# entirely outside this leg's scope, whose own symbol surface belongs to
# the lanes that own it. Scoping this audit to exactly the two files this
# leg's switch half depends on keeps the allow-list honest and avoids
# masking a real finding under an allow-list broadened for unrelated
# lanes.
#
# Method:
#   1. Build libms_context_audit.dylib from native/posix/ms_context.c and
#      native/posix/ms_context_aarch64.S (CC overrides the compiler).
#   2. `nm -u` its undefined symbols; every symbol must be either a system
#      library symbol or the public ms_context_* ABI.
#   3. `nm -gU --defined-only` its exported symbols; nothing private may be
#      exported either -- in particular, mjs__ctx_make_raw and
#      mjs_ctx_trampoline (.private_extern in the .S) must NOT appear here;
#      if they do, something about the build stopped that linkage
#      visibility contract from taking effect.
#   4. Screening order per symbol: the private-runtime pattern is applied
#      FIRST — a match is FORBIDDEN regardless of allow status. Symbols
#      that match neither the allow-list nor the private pattern are
#      reported as UNAUDITED[...] warnings instead of being silently
#      dropped.
#
# Exit codes: 0 pass | 1 forbidden symbols found | 2 RED: build failed |
#             3 tooling error.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CC=${CC:-cc}
OUT="$SCRIPT_DIR/.build"
mkdir -p "$OUT"

command -v "$CC" >/dev/null 2>&1 || { echo "T14 ERROR: $CC not found; set CC=<compiler>"; exit 3; }
command -v nm >/dev/null 2>&1 || { echo "T14 ERROR: nm not available"; exit 3; }

if ! "$CC" -arch arm64 -O2 -I "$repo/native/include" -c "$repo/native/posix/ms_context.c" -o "$OUT/t14_ms_context.o" 2>"$OUT/t14_ms_context.err"; then
    echo "T14 RED: failed to build native/posix/ms_context.c:"
    sed 's/^/  /' "$OUT/t14_ms_context.err"
    exit 2
fi
if ! "$CC" -arch arm64 -c "$repo/native/posix/ms_context_aarch64.S" -o "$OUT/t14_ms_context_aarch64.o" 2>"$OUT/t14_ms_context_aarch64.err"; then
    echo "T14 RED: failed to build native/posix/ms_context_aarch64.S:"
    sed 's/^/  /' "$OUT/t14_ms_context_aarch64.err"
    exit 2
fi
lib="$OUT/libms_context_audit.dylib"
if ! "$CC" -dynamiclib -o "$lib" "$OUT/t14_ms_context.o" "$OUT/t14_ms_context_aarch64.o" 2>"$OUT/t14_link.err"; then
    echo "T14 RED: failed to link the audit dylib:"
    sed 's/^/  /' "$OUT/t14_link.err"
    exit 2
fi

echo "T14: auditing $lib (native/posix/ms_context.c + ms_context_aarch64.S only)"

undef=$(nm -u "$lib" 2>/dev/null) || { echo "T14 ERROR: nm -u failed"; exit 3; }
defined=$(nm -gU --defined-only "$lib" 2>/dev/null) || { echo "T14 ERROR: nm failed on defined symbols"; exit 3; }

# Symbols this audit target is allowed to import: libc/libSystem surface
# plus its own public ms_context_* ABI. (No mjs_/mach_/pthread/etc needed
# here -- unlike the S0 spike or the full libmojito_sys.dylib, these two
# files only ever call memset-shaped compiler builtins, which -O2 inlines
# away for this fixed 200-byte struct, so the undefined-symbol list is
# expected to be empty in practice.)
allow='^_?(ms_context_|mem[a-z]*$|str[a-z]*$|bzero|bcmp|__stack_chk_|__error)'
private='_MLIR|__mlir|[Mm][Ll][Ii][Rr]|modart|[Aa]sync[Rr][Tt]|asyncrt|__mojo|_mojo|kgen|[Kk]gen|[Cc]oroutine|COROUTINE'
check_list() {
    _list="$1"
    _kind="$2"
    printf '%s\n' "$_list" | awk 'length($0) > 2 { for (i = 1; i <= NF; i++) if ($i ~ /^[A-Za-z_$][A-Za-z0-9_$]{3,}$/) print $i }' | sort -u | while IFS= read -r sym; do
        [ "$sym" = "_" ] && continue
        # Private-runtime pattern is applied FIRST: a match is forbidden
        # regardless of allow status.
        if printf '%s' "$sym" | grep -Eq "$private"; then
            echo "FORBIDDEN[$_kind] $sym"
        elif ! printf '%s' "$sym" | grep -Eq "$allow"; then
            echo "UNAUDITED[$_kind] $sym"
        fi
    done
}

forbidden="$( { check_list "$undef" undefined; check_list "$defined" defined; } | grep '^FORBIDDEN' || true)"
unaudited="$( { check_list "$undef" undefined; check_list "$defined" defined; } | grep '^UNAUDITED' || true )"

if [ -n "$unaudited" ]; then
    echo "T14 WARN: symbols matching neither the allow-list nor the private pattern:"
    printf '%s\n' "$unaudited"
fi

if [ -n "$forbidden" ]; then
    echo "T14 FAIL: private Mojo/Modular runtime symbols detected:"
    printf '%s\n' "$forbidden"
    exit 1
fi

# Belt+suspenders: mjs__ctx_make_raw and mjs_ctx_trampoline are
# .private_extern in the .S specifically so they never become part of a
# linked artifact's public surface. Confirm that directly rather than only
# relying on the allow/private pattern screen above.
if printf '%s\n' "$defined" | grep -q 'mjs__ctx_make_raw\|mjs_ctx_trampoline'; then
    echo "T14 FAIL: mjs__ctx_make_raw/mjs_ctx_trampoline are exported -- .private_extern did not take effect"
    exit 1
fi

echo "T14 PASS: no private Mojo async/coroutine/runtime symbols referenced or exported; mjs__ctx_make_raw/mjs_ctx_trampoline stay non-exported as designed."
exit 0
