#!/bin/sh
# mojito-sys S1 — memory sub-lane aggregate driver (issue #28, M6).
#
# Owned by the s1/memory-page lane. Runs every memory sub-lane suite under
# tests/s1/memory/<lane>/run.sh (page, vm, stack, ...) and collects a
# PASS/FAIL matrix. Exits nonzero if any sub-lane fails or a discovered
# run.sh cannot be executed.
#
# This file sits at the depth-2 position (tests/s1/memory/run.sh) that the
# build-lane driver tests/s1/run.sh discovers, so the whole memory block is
# visible to `make test-s1` through one entry point.
#
# Usage: tests/s1/memory/run.sh          (or: make test-s1 from the repo root)
#   MOJO=/path/to/mojo is passed through to sub-lane suites.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}

# Sub-lane suites: tests/s1/memory/<lane>/run.sh, sorted for a stable matrix.
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 2 -name run.sh 2>/dev/null | sort)

if [ -z "$lanes" ]; then
    echo "S1 memory: no sub-lane suites landed yet (tests/s1/memory/*/run.sh); all green by default."
    echo ""
    echo "S1 memory suite matrix (issue #28)"
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
echo "S1 memory suite matrix (issue #28)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
