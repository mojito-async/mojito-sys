#!/bin/sh
# mojito-sys S3.2 — NativeCondVar conformance lane runner (issue #58).
#
# Builds libmojito_sys.dylib (the Makefile picks up native/posix/*.c by
# wildcard), then drives BOTH layers of the s3-condvar surface:
#   - s3-condvar-mojo  — the §16 NativeCondVar wrapper conformance
#     (conformance.mojo, AOT-built per the b2 note in tests/s2/thread);
#   - s3-condvar-c     — the raw C smoke (condvar_smoke.c, linked
#     against the packaged dylib so a missing export is a hard failure);
#   - s3-sync-import   — package-path import check for the condvar
#     surface of mojito_sys.sync.
#
# TEST_NAME is "s3-condvar" (the precommit/known-red.tsv key while the
# lane is TDD-red). Prints '<row> PASS/FAIL' lines plus "RESULT: all
# green"; exits nonzero when any row fails.
#
# Usage: tests/s3/sync/condvar/run.sh    MOJO=/path/to/mojo

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_NAME="s3-condvar"
TEST_FILE="$SCRIPT_DIR/conformance.mojo"
SMOKE_FILE="$SCRIPT_DIR/condvar_smoke.c"
IMPORT_FILE="$SCRIPT_DIR/import_check.mojo"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_condvar.c included once it lands).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

matrix=""

# ---- Mojo wrapper conformance (AOT; see run_thread.sh b2 note) ----------
BIN="$BUILD_DIR/condvar_conformance"
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

echo "== $TEST_NAME (mojo wrapper)"
printf '%s\n' "$out" | sed 's/^/   | /'
if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: 8/8 PASSED"; then
    matrix="${matrix}s3-condvar-mojo PASS
"
else
    matrix="${matrix}s3-condvar-mojo FAIL
"
fi

# ---- C smoke against the frozen ABI --------------------------------------
cstatus=2
cout=""
if command -v "$CC" >/dev/null 2>&1; then
    CBIN="$BUILD_DIR/condvar_smoke"
    cout=$("$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
        "$SMOKE_FILE" "$REPO_ROOT/libmojito_sys.dylib" -o "$CBIN" 2>&1)
    cstatus=$?
    if [ $cstatus -eq 0 ]; then
        cout=$(env DYLD_LIBRARY_PATH="$REPO_ROOT" "$CBIN" 2>&1)
        cstatus=$?
    fi
else
    cout="cc not found; set CC=<path-to-cc>"
fi

echo "== $TEST_NAME (C smoke)"
printf '%s\n' "$cout" | sed 's/^/   | /'
if [ $cstatus -eq 0 ]; then
    matrix="${matrix}s3-condvar-c PASS
"
else
    matrix="${matrix}s3-condvar-c FAIL
"
fi

# ---- Import-surface coverage for the package path ------------------------
imp_status=0
imp_out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$IMPORT_FILE" 2>&1) || imp_status=$?

echo "== s3-sync-import"
printf '%s\n' "$imp_out" | sed 's/^/   | /'
if [ $imp_status -eq 0 ] && printf '%s' "$imp_out" | grep -q "condvar-import-ok"; then
    matrix="${matrix}s3-sync-import PASS
"
else
    matrix="${matrix}s3-sync-import FAIL
"
fi

echo ""
echo "S3.2 sync condvar conformance matrix (issue #58)"
printf '%s' "$matrix" | sed 's/^/  /'
case "$matrix" in
    *FAIL*)
        echo "RESULT: FAILED"
        exit 1
        ;;
esac
echo "RESULT: all green"
exit 0
