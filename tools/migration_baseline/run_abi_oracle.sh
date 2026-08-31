#!/bin/sh
# tools/migration_baseline/run_abi_oracle.sh — build + run abi_oracle.c
# (issue #122's ABI/OS-struct layout inventory) and commit its output.
#
# Modes:
#   (no args)   build the oracle against the packaged libmojito_sys.dylib
#               and write MOJO_MIGRATION_ABI_LAYOUT.jsonl at the repo root.
#   --check     rebuild + rerun into a temp file and diff against the
#               committed MOJO_MIGRATION_ABI_LAYOUT.jsonl; nonzero exit on
#               any drift (including the file not existing yet — the
#               RED-first state before this issue lands real numbers).
#
# Every line is valid JSON (one struct/typedef/constant per line); this
# script itself does not interpret the content, just verifies it parses
# and hasn't drifted. tools/migration_baseline/validate_baseline_jsonl.sh
# owns schema-level checks against the §38.16 style.
#
# Usage: tools/migration_baseline/run_abi_oracle.sh [--check]
#   CC=<cc> override the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CC=${CC:-cc}
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
BUILD="$REPO_ROOT/build/migration_baseline"
BIN="$BUILD/abi_oracle"
OUT="$REPO_ROOT/MOJO_MIGRATION_ABI_LAYOUT.jsonl"
MODE=${1:-generate}

if [ ! -f "$DYLIB" ]; then
    echo "== building $DYLIB"
    if ! make -C "$REPO_ROOT" libmojito_sys.dylib >/dev/null 2>&1; then
        echo "run_abi_oracle: \`make libmojito_sys.dylib\` failed"
        exit 2
    fi
fi

mkdir -p "$BUILD"
if ! "$CC" -Wall -Wextra -I"$REPO_ROOT/native/include" \
        "$SCRIPT_DIR/abi_oracle.c" "$DYLIB" -o "$BIN" 2>"$BUILD/build.err"; then
    echo "run_abi_oracle: build failed:"
    sed 's/^/    | /' "$BUILD/build.err"
    exit 2
fi

TMP=$(mktemp 2>/dev/null) || { echo "run_abi_oracle: mktemp failed"; exit 2; }
trap 'rm -f "$TMP" "$TMP.diff"' EXIT

if ! DYLD_LIBRARY_PATH="$REPO_ROOT" LD_LIBRARY_PATH="$REPO_ROOT" "$BIN" >"$TMP" 2>"$BUILD/run.err"; then
    echo "run_abi_oracle: oracle binary exited nonzero:"
    sed 's/^/    | /' "$BUILD/run.err"
    exit 2
fi

n=$(grep -c '.' "$TMP")

# Validate every non-blank line parses as JSON, using whichever of python3
# / node is available; if neither is, skip the parse check but still do
# the diff (the diff alone still catches drift).
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c '
import json, sys
n = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        json.loads(line)
        n += 1
sys.exit(0)
' "$TMP"; then
        echo "run_abi_oracle: oracle output is not all valid JSON Lines"
        exit 1
    fi
fi

if [ "$MODE" = "--check" ]; then
    if [ ! -f "$OUT" ]; then
        echo "run_abi_oracle: --check FAIL — $OUT does not exist yet"
        echo "   (regenerated $n rows; run without --check to commit them)"
        exit 1
    fi
    if ! diff -u "$OUT" "$TMP" >"$TMP.diff" 2>&1; then
        echo "run_abi_oracle: --check FAIL — committed layout drifted from"
        echo "   what this host's compiler actually produces:"
        sed 's/^/    | /' "$TMP.diff"
        exit 1
    fi
    echo "run_abi_oracle: --check PASS ($n rows, matches $OUT)"
    exit 0
fi

cp "$TMP" "$OUT"
echo "run_abi_oracle: wrote $n rows to $OUT"
exit 0
