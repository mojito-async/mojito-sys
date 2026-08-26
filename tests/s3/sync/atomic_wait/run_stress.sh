#!/bin/bash
# S3.4 fallback stress runner (issue #60): 256 distinct u32 keys hashing
# onto fewer physical slots, concurrent waiters, exact wake counts.
# Usage: tests/s3/sync/atomic_wait/run_stress.sh
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
CC=${CC:-cc}

make -C "$REPO_ROOT" libmojito_sys.dylib >/dev/null 2>&1 || {
    echo "ERROR: make libmojito_sys.dylib failed"; exit 2; }

BIN="$SCRIPT_DIR/.build/fallback_stress"
mkdir -p "$SCRIPT_DIR/.build"
"$CC" -O2 -g -Wall -Wextra -I"$REPO_ROOT/native/include" \
    "$SCRIPT_DIR/fallback_stress.c" "$REPO_ROOT/libmojito_sys.dylib" \
    -o "$BIN" || exit 2
DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN"
