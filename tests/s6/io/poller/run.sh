#!/bin/sh
# mojito-sys S6.3 — readiness poller conformance lane (issue #75).
#
# Runs the §38.7 poller conformance (conformance.mojo) against the packaged
# libmojito_sys.dylib under the repo-root package layout:
#   - register/modify/unregister; duplicate registration (last wins);
#   - readable/writable/immediate readiness; timeout with no events;
#   - multiple ready handles; token round trip + token reuse;
#   - close-while-registered; descriptor/handle reuse after close;
#   - stale OS events; readiness racing unregister;
#   - explicit EVFILT_USER wake (blocked waiter + sticky pre-wait);
#   - kqueue filter lifecycle; EOF/error cases; interrupt/retry mapping;
#   - registration scale tiers 1k/10k/100k where host limits permit;
#   - concurrent control operations; poller destruction.
#
# Builds the dylib first (the Makefile picks up native/posix/*.c by
# wildcard, so no Makefile edit is needed for this lane's sources).
#
# Usage: tests/s6/io/poller/run.sh    MOJO=/path/to/mojo CC=<cc>
#   Expects to be run from a checkout where `make` works at the repo root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s6-poller"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_poller.c included).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s4/time/*/run.sh);
# retry a bounded number of times, keeping the last output.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$TEST_FILE" 2>&1)
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
echo "S6.3 poller conformance matrix (issue #75)"
printf '%s' "$matrix" | tr ':' '\n' | sed 's/^/  /'
if printf '%s' "$matrix" | grep -q "FAIL"; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
