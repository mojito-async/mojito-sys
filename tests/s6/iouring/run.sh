#!/bin/sh
# tests/s6/iouring/run.sh — S6 io_uring teardown lane (issue #163).
#
# LINUX ONLY, and additionally needs MOJITO_IO_URING=1 and a kernel with
# io_uring.  On any other host the backend is the detect-and-exclude -ENOSYS
# stub and this lane exits 2, an ENVIRONMENT result, NOT 0.  That is
# deliberate: mojito-async#141's whole finding is that "I could not measure"
# must never be recorded as "nothing wrong", and this backend shipped with
# every behavioural conformance row printing UNSUPPORTED-PLATFORM.
#
# Exit: 0 all green, 1 RED, 2 environment / unsupported platform.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build/tests-s6-iouring"
CC=${CC:-cc}

DYLIB=""
for cand in "$REPO_ROOT/libmojito_sys.so" "$REPO_ROOT/libmojito_sys.dylib"; do
    [ -f "$cand" ] && DYLIB="$cand" && break
done
if [ -z "$DYLIB" ]; then
    echo "tests/s6/iouring: libmojito_sys not built; run \`make\` first."
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

mkdir -p "$BUILD_DIR" || exit 2
bin="$BUILD_DIR/iouring_teardown"
if ! $CC -std=c11 -O2 -g -Wall -Wextra -D_GNU_SOURCE \
        -I"$REPO_ROOT/native/include" \
        "$SCRIPT_DIR/iouring_teardown.c" "$DYLIB" -o "$bin" 2>&1; then
    echo "tests/s6/iouring: build failed"
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

out=$("$bin" 2>&1); st=$?
printf '%s\n' "$out"
# No VERDICT row on exit >= 2: an environment result is not a driver verdict,
# and a gate must never be able to allow-list one (mojito-async#141).
if [ "$st" -eq 0 ]; then
    printf 'VERDICT\ts6_iouring_teardown\tPASS\n'
elif [ "$st" -eq 1 ]; then
    printf 'VERDICT\ts6_iouring_teardown\tRED\n'
fi
exit "$st"
