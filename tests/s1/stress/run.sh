#!/bin/sh
# mojito-sys S1 stress lane — guarded-stack memory + stress tests (issue #31).
#
# Compiles the stress guard probe (t_guard_stress.c) once into .build/, then
# AOT-builds each Mojo driver against it (-Xlinker) with the repo root on the
# Mojo search path (-I), and runs them with the mojito-sys dylib findable via
# DYLD_LIBRARY_PATH. Prints a PASS/FAIL matrix; exits nonzero if any driver
# fails; prints "RESULT: all green" when clean.
#
# Until the build/vm/arrays native lanes merge, the mjs_* symbols these
# drivers drive are NOT resolvable, so every driver FAILS at build with a red
# unresolved-symbol verdict. That is the intended TDD red of issue #31, not a
# harness bug; the drivers need no change to go green once deps land and this
# branch is rebased. The C probe only provides the fork-based guard fault a
# Mojo driver cannot express safely; all mjs calls are made directly from Mojo
# via @extern abi("C").

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
OUT="$SCRIPT_DIR/.build"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
PROBE="$OUT/t_guard_stress.o"

DRIVERS="guard_page_test no_move_test growth_stress"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: cc not found on PATH; set CC=<path-to-cc>"
    echo "RESULT: toolchain unavailable"
    exit 2
fi
if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "RESULT: toolchain unavailable"
    exit 2
fi

mkdir -p "$OUT"

failures=0
say() { printf '%s\n' "$*"; }

# Build the shared guard-fork probe once.
if ! "$CC" -arch arm64 -c "$SCRIPT_DIR/t_guard_stress.c" -o "$PROBE"; then
    say "ERROR: probe build failed (t_guard_stress.c)"
    exit 2
fi

run_driver() { # <name>  name = <name>.mojo in SCRIPT_DIR
    name=$1
    driver="$SCRIPT_DIR/$name.mojo"
    bin="$OUT/$name"
    if ! "$MOJO" build "$driver" -o "$bin" \
        -I "$REPO_ROOT" -Xlinker "$PROBE" 2>"$OUT/$name.build.log"; then
        say "== $name FAIL (driver build)"
        tail -n 8 "$OUT/$name.build.log" | sed 's/^/     | /'
        failures=$((failures + 1))
        return
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" 2>&1)
    st=$?
    if [ $st -eq 0 ]; then
        say "== $name PASS"
    else
        say "== $name FAIL (exit $st)"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/     | /'
        failures=$((failures + 1))
    fi
}

say "== S1 stress lane (issue #31) — builds in $OUT"
for t in $DRIVERS; do
    run_driver "$t"
done

say ""
say "S1 stress matrix (issue #31)"
if [ "$failures" -ne 0 ]; then
    say "RESULT: $failures/3 FAILED"
    exit 1
fi
say "RESULT: all green"
exit 0