#!/bin/sh
# mojito-sys S1 stress lane — guarded-stack memory + stress tests (issue #31).
#
# Exit-code contract:
#   0  all drivers passed ("RESULT: all green")
#   1  one or more drivers failed (build or run)
#   2  RUN-ERROR: toolchain missing or libmojito_sys not built — run
#      `make test-s1` at the repo root first (sibling-lane convention).
#
# Compiles the guard probes (t_guard_stress.c) once into .build/, then
# AOT-builds each Mojo driver against the packaged libmojito_sys (-Xlinker,
# -I repo root for mojito_sys, -I this dir for the shared externs module)
# and runs them with the dylib findable via DYLD_LIBRARY_PATH (macOS) /
# LD_LIBRARY_PATH (elsewhere). Prints a PASS/FAIL matrix; each driver prints
# a grep-able "RESULT: <name> green" marker on success.
#
# TDD red: while the vm/stack native lanes (#29/#30) are unmerged, the
# packaged dylib lacks mjs_stack_alloc / mjs_vm_commit / mjs_stack_free, so
# every driver FAILS at link with an unresolved-symbol verdict. That is the
# intended red of issue #31 — the drivers need no change to go green once
# those lanes land and merge AFTER them (see PR body ordering note).
# The C probe only provides fork-based deliberate faults a Mojo driver
# cannot express safely; all mjs calls are made from Mojo via @extern abi("C")
# through tests/s1/stress/stress_externs.mojo.
#
# Portability: no -arch flag; library suffix and runtime search-path env are
# derived from uname -s (review M4).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
OUT="$SCRIPT_DIR/.build"
BUILD_RETRIES=3

case "$(uname -s)" in
    Darwin)
        SOEXT=dylib
        LD_ENV=DYLD_LIBRARY_PATH
        ;;
    *)
        SOEXT=so
        LD_ENV=LD_LIBRARY_PATH
        ;;
esac
DYLIB="$REPO_ROOT/libmojito_sys.$SOEXT"
PROBE="$OUT/t_guard_stress.o"

DRIVERS="guard_page_test no_move_test growth_stress_test"

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
if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found; run \`make test-s1\` at the repo root first."
    echo "RESULT: RUN-ERROR (library not built)"
    exit 2
fi

mkdir -p "$OUT"

failures=0
say() { printf '%s\n' "$*"; }

# Build the shared guard-fork probe once.
if ! "$CC" -c "$SCRIPT_DIR/t_guard_stress.c" -o "$PROBE"; then
    say "ERROR: probe build failed (t_guard_stress.c)"
    exit 2
fi

run_driver() { # <name>  name = <name>.mojo in SCRIPT_DIR
    name=$1
    driver="$SCRIPT_DIR/$name.mojo"
    bin="$OUT/$name"
    log="$OUT/$name.build.log"
    attempt=1
    built=0
    while [ $attempt -le $BUILD_RETRIES ]; do
        if "$MOJO" build "$driver" -o "$bin" \
            -I "$REPO_ROOT" -I "$SCRIPT_DIR" \
            -Xlinker "$PROBE" -Xlinker "-L$REPO_ROOT" -Xlinker -lmojito_sys \
            2>"$log"; then
            built=1
            break
        fi
        attempt=$((attempt + 1))
    done
    if [ $built -eq 0 ]; then
        say "== $name FAIL (driver build, after $BUILD_RETRIES attempts)"
        tail -n 8 "$log" | sed 's/^/     | /'
        failures=$((failures + 1))
        return
    fi
    out=$(env "$LD_ENV=$REPO_ROOT" "$bin" 2>&1)
    st=$?
    if [ $st -eq 0 ]; then
        say "== $name PASS"
    else
        say "== $name FAIL (exit $st)"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/     | /'
        failures=$((failures + 1))
    fi
}

total=$(printf '%s\n' $DRIVERS | wc -l | tr -d ' ')

say "== S1 stress lane (issue #31) — builds in $OUT"
for t in $DRIVERS; do
    run_driver "$t"
done

say ""
say "S1 stress matrix (issue #31)"
if [ "$failures" -ne 0 ]; then
    say "RESULT: $failures/$total FAILED"
    exit 1
fi
say "RESULT: all green"
exit 0
