#!/bin/sh
# mojito-sys S5 aggregator — runs every landed lane suite under
# tests/s5/<lane>/run.sh (same discovery shape as tests/s1/run.sh).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 2 -name run.sh 2>/dev/null | sort)

if [ -z "$lanes" ]; then
    echo "S5: no lane suites landed yet (tests/s5/*/run.sh); all green by default."
    echo ""
    echo "S5 suite matrix"
    echo "  (no lanes)"
    echo ""
    echo "RESULT: all green"
    exit 0
fi

failures=0
matrix=""
for lane_sh in $lanes; do
    lane=$(basename "$(CDPATH= cd -- "$SCRIPT_DIR/$(dirname "$lane_sh")" && pwd)")
    printf '== %s\n' "$lane"
    out=$("$SCRIPT_DIR/$lane_sh" 2>&1)
    status=$?
    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        row="$lane PASS"
    else
        row="$lane FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    printf '%s\n' "$out" | tail -n 4 | sed 's/^/   | /'
done

echo ""
echo "S5 suite matrix"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
