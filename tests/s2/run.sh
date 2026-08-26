#!/bin/sh
# mojito-sys S2 — suite driver (umbrella aggregator, issues #54/#56 folds).
#
# S1 find-style: discovers every S2 lane suite under tests/s2/<lane>/run.sh
# and runs them, collecting a PASS/FAIL matrix. Granular per-lane targets
# (make test-s2-native/conformance/stress/integration/pkg) are unchanged;
# future lanes inherit discovery by dropping a <lane>/run.sh — no new gate
# stage wiring needed.
#
# Usage: tests/s2/run.sh           (from the repo root)
#   MOJO=/path/to/mojo is passed through to lane suites.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Top-level lane suites only: tests/s2/<lane>/run.sh, sorted for stability
# (nested suites belong to their lane's own runner).
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 2 -name run.sh | sort)

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
echo "S2 suite matrix"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
