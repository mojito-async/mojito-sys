#!/bin/sh
# mojito-sys S2 — native C smoke driver (S2.3 tls lane, issue #50).
#
# Builds libmojito_sys.dylib at the repo root if needed, then compiles every
# tests/s2/native/*_smoke.c against it (linking the dylib pins each smoke
# consumer to the real export table) and runs each binary. Prints
# '<suite-name> PASS/FAIL' rows plus a RESULT line:
#     RESULT: all green
# Exits nonzero when any smoke fails to build or run. The dylib link makes
# missing exports a hard failure — the TDD-red phase of each lane fails
# here until its native implementation lands.
#
# Usage: tests/s2/native/run.sh     CC=/path/to/cc optional.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
OUT="$SCRIPT_DIR/.build"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"

if ! make -C "$REPO_ROOT" "$DYLIB" >/dev/null 2>&1; then
    echo "ERROR: cannot build $DYLIB; run \`make\` at the repo root."
    exit 2
fi
mkdir -p "$OUT"

failures=0
matrix=""
for src in "$SCRIPT_DIR"/*_smoke.c; do
    [ -e "$src" ] || continue
    name="s2-$(basename "$src" _smoke.c)"
    bin="$OUT/$(basename "$src" .c)"
    if ! "$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
            "$src" "$DYLIB" -o "$bin" >"$OUT/$name.build.log" 2>&1; then
        printf '%s FAIL\n' "$name"
        tail -n 8 "$OUT/$name.build.log" | sed 's/^/    | /'
        matrix="$name FAIL
"
        failures=$((failures + 1))
        continue
    fi
    log="$OUT/$name.run.log"
    if env DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" >"$log" 2>&1; then
        printf '%s PASS\n' "$name"
        matrix="$matrix$name PASS
"
    else
        printf '%s FAIL\n' "$name"
        tail -n 12 "$log" | sed 's/^/    | /'
        matrix="$matrix$name FAIL
"
        failures=$((failures + 1))
    fi
done

echo ""
echo "S2 native smoke matrix (issue #50)"
printf '%s' "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
