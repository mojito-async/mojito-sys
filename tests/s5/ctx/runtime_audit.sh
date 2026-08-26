#!/bin/sh
# runtime_audit.sh — S5.2 T14-style runtime-independence audit for the
# packaged libmojito_sys.dylib (issue #65).
#
# Fixes the PR#21-era BLOCK finding "T14 nm no-op": Apple llvm-nm CANCELS
# -u with -U, so an audit written as `nm -uU` compares an EMPTY undefined
# set and proves nothing. This audit is non-vacuous by construction:
#   1. plain `nm -u` collects the undefined set;
#   2. VACUITY GUARD — FAIL unless the set is non-empty AND contains a
#      known libc import anchor, proving the audit sees real imports;
#   3. EXPECTED-ABSENCE LIST — zero Modular/Mojo private runtime symbols
#      may appear in the undefined OR the exported set;
#   4. internals discipline — the asm bookkeeping/helper privates
#      (.private_extern/.hidden) must stay out of the export table.
#
# Usage: tests/s5/ctx/runtime_audit.sh   (exit 0 = clean, 1 = violation)

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
TEST_NAME="s5_ctx_runtime_audit"

[ -f "$DYLIB" ] || { echo "$TEST_NAME: $DYLIB missing; run \`make\` first"; exit 2; }
command -v nm >/dev/null 2>&1 || { echo "$TEST_NAME ERROR: nm unavailable"; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

echo "== $TEST_NAME (issue #65: non-vacuous T14)"
echo "auditing $DYLIB"

# 1. plain `nm -u` — NEVER `-uU` (cancels out on Apple llvm-nm => no-op).
nm -u "$DYLIB" >"$TMP/undef_raw" 2>/dev/null || {
    echo "  AUDIT FAIL: nm -u failed"; exit 1;
}
sed -n 's/^_//p' "$TMP/undef_raw" | sort -u >"$TMP/undef"
nm -gU "$DYLIB" | awk 'NF >= 3 {print $3}' | sed 's/^_//' | sort -u >"$TMP/exported"

failures=0

# 2. Vacuity guard ---------------------------------------------------------
if [ ! -s "$TMP/undef" ]; then
    echo "  AUDIT FAIL: undefined set is EMPTY — the audit would be a no-op"
    failures=$((failures + 1))
elif ! grep -Eq '^(memset|memcpy|mmap|mprotect|malloc|sysconf|dyld)' "$TMP/undef"; then
    echo "  AUDIT FAIL: undefined set lacks any known libc/dyld anchor;"
    echo "    the import view is unreliable (vacuous-audit guard)"
    failures=$((failures + 1))
else
    echo "  vacuity guard (undefined set non-empty, libc anchor seen)  OK"
fi

# 3. Expected-absence list: Modular/Mojo private runtime symbols ----------
FORBIDDEN='(^|_)MLIR|__mlir|modart|asyncRT|kgen|coroutine|__mojo'
forbidden_hits=$(cat "$TMP/undef" "$TMP/exported" | grep -E "$FORBIDDEN" || true)
if [ -n "$forbidden_hits" ]; then
    echo "  AUDIT FAIL: Modular/Mojo private runtime symbols detected:"
    printf '%s\n' "$forbidden_hits" | sed 's/^/    | /'
    failures=$((failures + 1))
else
    echo "  expected-absence list: 0 Modular-runtime symbols (undef+exported)  OK"
fi

# 4. Internals stay private ----------------------------------------------
leaked=$(grep -E '^(mjs__ctx_make_raw|mjs_ctx_trampoline|ms_last_from|ms_last_to|mjs_resume_tab)$' \
    "$TMP/exported" || true)
if [ -n "$leaked" ]; then
    echo "  AUDIT FAIL: internal symbols leaked into the export table:"
    printf '%s\n' "$leaked" | sed 's/^/    | /'
    failures=$((failures + 1))
else
    echo "  internals (make_raw/trampoline/bookkeeping) not exported  OK"
fi

if [ "$failures" -ne 0 ]; then
    echo "RESULT: $TEST_NAME FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
