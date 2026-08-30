#!/bin/sh
# tests/s6/iouring_submit/run.sh — S6 io_uring submit-return contract lane
# (issue #167).
#
# LINUX ONLY, and additionally needs a NATIVE kernel with io_uring.  The
# driver sets MOJITO_IO_URING=1 itself so the capability flag can never be
# the reason this lane quietly skips; what it will not do is fake a kernel.
# On any host where mjs_iouring_probe() is 0 — Darwin, emulated linux/amd64
# under Rosetta or qemu, or a seccomp profile that refuses io_uring_setup —
# the driver exits 2, an ENVIRONMENT result, NOT 0.  That is deliberate:
# mojito-async#141's finding is that "I could not measure" must never be
# recorded as "nothing wrong", and #167 was very nearly missed exactly that
# way, by reading an emulated ENOSYS as a pass.
#
# Exit: 0 all green, 1 RED, 2 environment / unsupported platform.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build/tests-s6-iouring-submit"
CC=${CC:-cc}

DYLIB=""
for cand in "$REPO_ROOT/libmojito_sys.so" "$REPO_ROOT/libmojito_sys.dylib"; do
    [ -f "$cand" ] && DYLIB="$cand" && break
done
if [ -z "$DYLIB" ]; then
    echo "tests/s6/iouring_submit: libmojito_sys not built; run \`make\` first."
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

mkdir -p "$BUILD_DIR" || exit 2
bin="$BUILD_DIR/iouring_submit_contract"
if ! $CC -std=c11 -O2 -g -Wall -Wextra -D_GNU_SOURCE \
        -I"$REPO_ROOT/native/include" \
        "$SCRIPT_DIR/iouring_submit_contract.c" "$DYLIB" -o "$bin" 2>&1; then
    echo "tests/s6/iouring_submit: build failed"
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

out=$("$bin" 2>&1); st=$?
printf '%s\n' "$out"
# No VERDICT row on exit >= 2: an environment result is not a driver verdict,
# and a gate must never be able to allow-list one (mojito-async#141).
if [ "$st" -eq 0 ]; then
    printf 'VERDICT\ts6_iouring_submit_contract\tPASS\n'
elif [ "$st" -eq 1 ]; then
    printf 'VERDICT\ts6_iouring_submit_contract\tRED\n'
fi
exit "$st"
