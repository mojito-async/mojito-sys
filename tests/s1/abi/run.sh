#!/bin/sh
# mojito-sys S1 — abi test-suite driver (issue #24/#25).
#
# Runs every lane runner below tests/s1/abi/ (discovered, not hardcoded —
# review PR #34, H3). Each lane owns its own runner and prints its own
# matrix; nonzero exits are propagated.
#
# Contract lines consumed by the S1 umbrella driver (s1/build):
#   print "RESULT: all green"  on success
#   print "RESULT: <n> FAILED" on any failure

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Discover lane runners: tests/s1/abi/*/run.sh (sorted, deterministic).
RUNNERS=$(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name run.sh | sort)

if [ -z "$RUNNERS" ]; then
    echo "ERROR: no lane runners found under $SCRIPT_DIR"
    echo "RESULT: 1 FAILED"
    exit 1
fi

lane_failures=0
count=0
for runner in $RUNNERS; do
    count=$((count + 1))
    if [ ! -x "$runner" ]; then
        echo "s1/abi lane FAIL (runner not executable: $runner)"
        lane_failures=$((lane_failures + 1))
        continue
    fi
    if ! "$runner"; then
        lane_failures=$((lane_failures + 1))
    fi
    echo ""
done

if [ "$lane_failures" -ne 0 ]; then
    echo "RESULT: $lane_failures/$count FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
