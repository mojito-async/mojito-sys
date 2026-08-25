#!/bin/sh
# mojito-sys S1 — packaged-library conformance lane (issue #24).
#
# Four checks over the packaged libmojito_sys.dylib + mojito_sys package:
#   1. header-shape   — compile a TU that type-checks EVERY entry point of
#                       the frozen native/include/mojito_sys.h (smoke.c);
#   2. link+run       — a C consumer of the implemented exports links
#                       against the dylib and validates runtime values
#                       (link_smoke.c): ABI version + page size;
#   3. export table   — `nm -gU` of the dylib must equal tests/s1/pkg/
#                       exports.txt in BOTH directions (panel H2: gaps are
#                       loud, not silent; lanes append on landing);
#   4. mojo import    — the `mojito_sys` package import path compiles and
#                       runs with -I <repo root> (import_check.mojo).
#
# Usage: tests/s1/pkg/run.sh    MOJO=/path/to/mojo CC=/path/to/cc (optional)

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
OUT="$SCRIPT_DIR/.build"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"

failures=0
check() { # <name> <command...>
    name=$1
    shift
    log="$OUT/$name.log"
    if ! "$@" >"$log" 2>&1; then
        printf '%s FAIL\n' "$name"
        tail -n 8 "$log" | sed 's/^/    | /'
        failures=$((failures + 1))
        return 1
    fi
    printf '%s PASS\n' "$name"
}

command -v "$CC" >/dev/null 2>&1 || { echo "ERROR: CC=$CC not found"; exit 2; }
[ -f "$DYLIB" ] || { echo "ERROR: $DYLIB not found; run \`make\` at the repo root first."; exit 2; }

mkdir -p "$OUT"

# 1. Frozen-header ABI shape: every declared signature type-checked.
check header-shape "$CC" -I"$REPO_ROOT/native/include" -c "$SCRIPT_DIR/smoke.c" -o "$OUT/smoke.o"
# 2. Link + run a consumer of the implemented export set.
if check link-smoke "$CC" -I"$REPO_ROOT/native/include" "$SCRIPT_DIR/link_smoke.c" "$DYLIB" -o "$OUT/link_smoke"; then
    check link-smoke-run env DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/link_smoke"
fi

# 3. Packaging conformance: dylib export table == expected list, exactly.
nm -gU "$DYLIB" | awk 'NF >= 3 {print $3}' | sed 's/^_//' | sort >"$OUT/exports.actual"
sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$SCRIPT_DIR/exports.txt" | sed 's/[[:space:]]//g' | sort >"$OUT/exports.expected"
if diff -u "$OUT/exports.expected" "$OUT/exports.actual" >"$OUT/exports.diff"; then
    echo "export-conformance PASS"
else
    echo "export-conformance FAIL (dylib export table != exports.txt)"
    failures=$((failures + 1))
fi

# 4. Mojo package scaffold imports and loads from the repo root.
check mojo-pkg-import "$MOJO" -I "$REPO_ROOT" "$SCRIPT_DIR/import_check.mojo"

if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
