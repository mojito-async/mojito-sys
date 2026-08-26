#!/bin/sh
# mojito-sys S3 — suite driver (umbrella aggregator, issue #62 fold).
#
# S2 find-style: discovers every S3 lane suite under
# tests/s3/<domain>/<lane>/run.sh and runs them, collecting a PASS/FAIL
# matrix. Future lanes inherit discovery by dropping a <lane>/run.sh —
# no new gate stage wiring needed.
#
# Usage: tests/s3/run.sh           (from the repo root)
#   MOJO=/path/to/mojo is passed through to lane suites.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Lane suites are one level deeper than S2: tests/s3/<domain>/<lane>/run.sh,
# sorted for stability.
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 3 -maxdepth 3 -name run.sh | sort)

failures=0
matrix=""
for lane_sh in $lanes; do
    lane=$(echo "$lane_sh" | sed 's|^\./||; s|/run\.sh$||')
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
echo "S3 suite matrix"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
