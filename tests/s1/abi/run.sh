#!/bin/sh
# mojito-sys S1 — abi/test-suite entry point (issue #24/#25).
#
# Runs every S1 abi lane test runner below tests/s1/abi/. Each lane owns
# its own runner and prints its own matrix; nonzero exits are propagated.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

RUNNERS="types"

failures=0
for r in $RUNNERS; do
    runner="$SCRIPT_DIR/$r/run.sh"
    if [ ! -x "$runner" ]; then
        echo "s1/abi/$r FAIL (runner missing)"
        failures=$((failures + 1))
        continue
    fi
    if ! "$runner"; then
        failures=$((failures + 1))
    fi
    echo ""
done

if [ "$failures" -ne 0 ]; then
    echo "S1 abi suite: $failures lane(s) FAILED"
    exit 1
fi
echo "S1 abi suite: all lanes green"
exit 0