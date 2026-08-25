#!/bin/sh
# mojito-sys S1 — suite driver (build lane, issue #24).
#
# Discovers every S1 lane suite under tests/s1/<lane>/run.sh and runs them,
# collecting a PASS/FAIL matrix. The overall result line is:
#     RESULT: all green
# and the script exits nonzero if any lane suite fails or a required lane
# run.sh cannot be executed.
#
# Lanes that have not landed yet are simply absent: with zero lane suites the
# driver still reports a green RESULT so the build-lane commit and the
# pre-commit gate (make test-s1) stay PASS until every lane merges.
#
# Usage: tests/s1/run.sh          (or: make test-s1 from the repo root)
#   MOJO=/path/to/mojo is passed through to lane suites.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}

# Lane suites: tests/s1/<lane>/run.sh, sorted for a stable matrix.
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 2 -name run.sh 2>/dev/null | sort)

if [ -z "$lanes" ]; then
    echo "S1: no lane suites landed yet (tests/s1/*/run.sh); all green by default."
    echo ""
    echo "S1 suite matrix (issue #24)"
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
echo "S1 suite matrix (issue #24)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
