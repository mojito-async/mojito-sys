#!/bin/sh
# mojito-sys S6.2 — non-blocking socket conformance lane (issue #74).
#
# Runs the §38.8 socket conformance (conformance.mojo) against the packaged
# libmojito_sys.dylib under the repo-root package layout:
#   - create/bind/listen/connect/accept; non-blocking configuration;
#   - send/recv incl. partial transfers; shutdown/close; EOF;
#   - address conversion; IPv4 + IPv6 + Unix-domain (loopback/local only);
#   - connection refusal; peer reset; double-close prevention;
#   - EINTR/EAGAIN mapping per §38.11 (simulated + live EAGAIN);
#   - never-parks proof: every non-blocking op returns within a hard bound.
#
# Builds the dylib first (the Makefile picks up native/posix/*.c by
# wildcard, so no Makefile edit is needed for this lane's sources).
#
# Usage: tests/s6/io/socket/run.sh    MOJO=/path/to/mojo CC=<cc>
#   Expects to be run from a checkout where `make` works at the repo root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/conformance.mojo"
TEST_NAME="s6-socket"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_socket.c included).
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
echo "S6.2 socket conformance matrix (issue #74)"
printf '%s' "$matrix" | tr ':' '\n' | sed 's/^/  /'
if printf '%s' "$matrix" | grep -q "FAIL"; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
