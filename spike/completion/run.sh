#!/bin/sh
# mojito-sys S6.5 — completion interface spike probe (issue #77).
#
# Runs the §27.2 completion-interface SKETCH self-check
# (interface_probe.mojo + completion_sketch.mojo) as a runnable design spike.
# The backend is a pure-Mojo mock ring (this host is darwin: no io_uring), so
# NO native library build is required — the spike documents the interface
# SHAPE and proves the behavioural surface (submit/get_events/
# wait_completions/cancel/wake, batch acquisition, token round-trip).
#
# Usage: spike/completion/run.sh    MOJO=/path/to/mojo
#   Expects to be run from a checkout of the repository.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"
TEST_NAME="s6-completion-probe"

TEST_FILE="$SCRIPT_DIR/interface_probe.mojo"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# The b2 toolchain intermittently segfaults while lowering modules (precedent:
# tests/s4/time/*/run.sh); retry a bounded number of times, keeping the last
# output. The probe imports its sibling completion_sketch.mojo relative to
# itself, so it is run from its own directory.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$(cd "$SCRIPT_DIR" && "$MOJO" run interface_probe.mojo 2>&1)
    status=$?
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2 # compiler crash: retry
    fi
done

matrix=""
echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    matrix="$TEST_NAME PASS
:"
else
    matrix="$TEST_NAME FAIL
:"
fi

echo ""
echo "S6.5 completion interface spike matrix (issue #77)"
printf '%s' "$matrix" | tr ':' '\n' | sed 's/^/  /'
if printf '%s' "$matrix" | grep -q "FAIL"; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0