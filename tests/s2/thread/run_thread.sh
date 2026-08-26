#!/bin/sh
# mojito-sys S2 — NativeThread Mojo-wrapper conformance lane runner (#49).
#
# Per-lane runner invoked by the canonical tests/s2/thread/run.sh union
# driver (PR #94); TEST_NAME matches the gate's known-red/allow-list key.
#
# Runs the §11 thread conformance (thread_test.mojo) plus the
# mojito_sys.thread import check against the packaged libmojito_sys.dylib
# under the repo-root package layout:
#   - userdata-counter spawn; entry-status propagation through join;
#   - join-twice raises -EINVAL;
#   - detach clean exit incl. T** consume semantics (handle NULLing);
#   - name round-trip (child pthread_getname_np), ENAMETOOLONG, NULL-name;
#   - native_thread_id + current-thread rename;
#   - 100 sequential spawn/join + spawn/detach cycles (leak-clean smoke).
#
# Builds the dylib first (the Makefile picks up native/posix/*.c by
# wildcard, so no Makefile edit is needed for this lane's sources).
#
# Usage: tests/s2/thread/run_thread.sh    MOJO=/path/to/mojo

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/thread_test.mojo"
IMPORT_FILE="$SCRIPT_DIR/import_check.mojo"
TEST_NAME="s2-thread-mojo"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_thread.c included).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s1/memory/vm/run.sh);
# retry a bounded number of times, keeping the last output.
# b2 note (#49): this suite is built AOT (mojo build) rather than `mojo run`
# — the JIT front-end deterministically SIGSEGVs lowering the test module
# against the wrapper; AOT lowers cleanly and keeps the retry bounded.
BIN="$BUILD_DIR/thread_conformance"
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" build -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" -o "$BIN" "$TEST_FILE" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
        out=$(env DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN" 2>&1)
        status=$?
    fi
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2  # compiler crash: retry
    fi
done

echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

matrix=""
if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: 8/8 PASSED"; then
    matrix="$TEST_NAME PASS
"
else
    matrix="$TEST_NAME FAIL
"
fi

# Import-surface coverage for the package path.
imp_status=0
imp_out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$IMPORT_FILE" 2>&1) || imp_status=$?

echo "== s2-thread-import"
printf '%s\n' "$imp_out" | sed 's/^/   | /'
if [ $imp_status -eq 0 ] && printf '%s' "$imp_out" | grep -q "thread-import-ok"; then
    matrix="${matrix}s2-thread-import PASS
"
else
    matrix="${matrix}s2-thread-import FAIL
"
fi

echo ""
echo "S2 thread wrapper conformance matrix (issue #49)"
printf '%s' "$matrix" | sed 's/^/  /'
case "$matrix" in
    *"FAIL"*)
        echo "RESULT: FAILED"
        exit 1
        ;;
esac
echo "RESULT: all green"
exit 0
