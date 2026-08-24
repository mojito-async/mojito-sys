#!/bin/sh
# mojito-sys S1 — packaged-library smoke lane (issue #24).
#
# Links a C translation unit that references every entry point declared in
# native/include/mojito_sys.h against libmojito_sys.dylib, so a missing
# export is a red build, not a load-time surprise.
#
# RED until the memory-vm / memory-stack lanes land (their entry points are
# declared by the frozen header but not implemented). Covered by the
# aggregate `s1-tests` known-red row until all S1 lanes merge.
#
# Usage: tests/s1/pkg/run.sh    MOJO=/path/to/mojo CC=/path/to/cc (optional)

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
OUT="$SCRIPT_DIR/.build"

failures=0
say() { printf '%s\n' "$*"; }

if ! command -v "$CC" >/dev/null 2>&1; then
    say "ERROR: CC=$CC not found"
    exit 2
fi
if [ ! -f "$REPO_ROOT/libmojito_sys.dylib" ]; then
    say "ERROR: $REPO_ROOT/libmojito_sys.dylib not found; run \`make\` at the repo root first."
    exit 2
fi

mkdir -p "$OUT"

# 1. Compile the header consumer.
if ! "$CC" -I"$REPO_ROOT/native/include" -c "$SCRIPT_DIR/smoke.c" -o "$OUT/smoke.o" 2>"$OUT/compile.log"; then
    say "smoke-header-abi FAIL (compile)"
    sed 's/^/    | /' "$OUT/compile.log" | tail -n 8
    say "RESULT: 1 FAILED"
    exit 1
fi

# 2. Link against the packaged dylib (unresolved exports = red).
if ! "$CC" "$OUT/smoke.o" "$REPO_ROOT/libmojito_sys.dylib" -o "$OUT/smoke" 2>"$OUT/link.log"; then
    say "smoke-header-abi FAIL (link: declared entry point not exported)"
    sed 's/^/    | /' "$OUT/link.log" | tail -n 8
    say "RESULT: 1 FAILED"
    exit 1
fi

# 3. Run it (does not deref anything; returns 0).
if ! DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/smoke" >/dev/null 2>&1; then
    say "smoke-header-abi FAIL (run)"
    say "RESULT: 1 FAILED"
    exit 1
fi

say "smoke-header-abi PASS"
say "smoke-header-compile PASS"
say "RESULT: all green"
exit 0