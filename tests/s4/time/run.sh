#!/bin/sh
# mojito-sys S4 — time sub-lane aggregate driver (issue #63).
#
# Runs every time sub-lane suite under tests/s4/time/<lane>/run.sh
# (monotonic, ...) and collects a PASS/FAIL matrix, mirroring the S1
# depth-2 discovery pattern (tests/s1/memory/run.sh): this file sits at
# the discoverable depth-2 position so the whole time block is visible
# through one entry point.
#
# Usage: tests/s4/time/run.sh
#   MOJO=/path/to/mojo is passed through to sub-lane suites.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}

# Sub-lane suites: tests/s4/time/<lane>/run.sh, sorted for a stable matrix.
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 2 -name run.sh 2>/dev/null | sort)

if [ -z "$lanes" ]; then
    echo "S4 time: no sub-lane suites landed yet (tests/s4/time/*/run.sh); all green by default."
    echo ""
    echo "S4 time suite matrix (issue #63)"
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
echo "S4 time suite matrix (issue #63)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
