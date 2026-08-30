#!/bin/sh
# tests/contract_sweep/run.sh — ABI-wide contract sweep runner
# (mojito-async#170, fix item 1). Mirrors tests/s6/iouring_submit/run.sh's
# build-then-run shape.
#
# Runs everywhere (no platform guard): every subsystem this driver touches
# either executes for real on this host, or degrades to a real, in-contract
# -ENOSYS this driver itself observes and sweeps (epoll off Linux, io_uring
# without host support or MOJITO_IO_URING=1) — see contract_sweep.c's own
# header for why that means there is no host on which this driver has
# nothing to measure, hence no ENVIRONMENT (exit 2) outcome here.
#
# Exit: 0 all green, 1 RED (a positive rc observed, or an internal
# assertion failed), 2 the dylib is not built yet.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build/tests-contract-sweep"
CC=${CC:-cc}

DYLIB=""
for cand in "$REPO_ROOT/libmojito_sys.so" "$REPO_ROOT/libmojito_sys.dylib"; do
    [ -f "$cand" ] && DYLIB="$cand" && break
done
if [ -z "$DYLIB" ]; then
    echo "tests/contract_sweep: libmojito_sys not built; run \`make\` first."
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

mkdir -p "$BUILD_DIR" || exit 2
bin="$BUILD_DIR/contract_sweep"
if ! $CC -std=c11 -O2 -g -Wall -Wextra -D_GNU_SOURCE \
        -I"$REPO_ROOT/native/include" \
        "$SCRIPT_DIR/contract_sweep.c" "$DYLIB" -o "$bin" 2>&1; then
    echo "tests/contract_sweep: build failed"
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

out=$("$bin" 2>&1); st=$?
printf '%s\n' "$out"
if [ "$st" -eq 0 ]; then
    printf 'VERDICT\tcontract_sweep\tPASS\n'
elif [ "$st" -eq 1 ]; then
    printf 'VERDICT\tcontract_sweep\tRED\n'
fi
exit "$st"
