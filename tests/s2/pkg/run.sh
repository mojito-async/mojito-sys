#!/bin/sh
# mojito-sys S2.9 — packaged-library conformance lane, thread area (#56).
#
# Extends the tests/s1/pkg pattern over the packaged libmojito_sys.dylib +
# mojito_sys.thread package:
#   1. link+run   — a C consumer addressing EVERY mjs_ symbol added by the
#                   S2 lanes (thread / tls / cpu sets) links against the
#                   dylib and runs two non-destructive probes
#                   (link_smoke.c); a missing export is a link failure.
#   2. mojo import— every mojito_sys.thread module imports and resolves its
#                   public surface from the repo root (import_check.mojo).
#
# The frozen-header shape check and the exact export-table diff stay owned
# by tests/s1/pkg (single source of truth for exports.txt); this lane pins
# the S2 additions from the CONSUMER side.
#
# Usage: tests/s2/pkg/run.sh    MOJO=/path/to/mojo CC=/path/to/cc (optional)

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
command -v "$MOJO" >/dev/null 2>&1 || { echo "ERROR: MOJO=$MOJO not found"; exit 2; }
[ -f "$DYLIB" ] || { echo "ERROR: $DYLIB not found; run \`make\` at the repo root first."; exit 2; }

mkdir -p "$OUT"

# 1. Link + run a consumer of the full S2 export set (thread/tls/cpu).
if check s2-link-smoke "$CC" -I"$REPO_ROOT/native/include" \
        "$SCRIPT_DIR/link_smoke.c" "$DYLIB" -o "$OUT/link_smoke"; then
    check s2-link-smoke-run env DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/link_smoke"
fi

# 2. Every mojito_sys.thread module imports + resolves from the repo root.
check s2-pkg-import "$MOJO" -I "$REPO_ROOT" "$SCRIPT_DIR/import_check.mojo"

if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
