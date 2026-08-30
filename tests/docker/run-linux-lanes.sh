#!/bin/sh
# tests/docker/run-linux-lanes.sh — run the Linux-only S6 I/O lanes inside a
# container, from any host.
#
# WHY THIS EXISTS.  The lanes under tests/s6 exercise backends that only
# exist on Linux.  On a macOS dev host every entry point is the -ENOSYS stub
# and the lanes exit 2 (environment), which is honest but proves nothing.
# This script gives them a real Linux kernel without asking anyone to own a
# Linux box, and without waiting for CI.
#
# The repository is mounted READ-ONLY and copied inside the container before
# anything is built, so a run never writes into the host tree — no build
# artifacts, no libmojito_sys.so, nothing to clean up afterwards.
#
# NATIVE ARCHITECTURE ONLY, and enforced.  Docker Desktop will happily run a
# linux/amd64 image on an Apple-silicon host through Rosetta, and under that
# emulation io_uring_setup returns ENOSYS.  An io_uring lane then reports
# UNSUPPORTED-PLATFORM, which looks like a skip and is really "the kernel you
# thought you were testing was never there".  Issue #167 was very nearly
# missed that way.  So the platform is pinned to the host's own architecture
# and re-checked from inside the container: a mismatch is exit 2, never a
# verdict.
#
# Usage:
#   tests/docker/run-linux-lanes.sh                 # every lane under tests/s6
#   tests/docker/run-linux-lanes.sh iouring_submit  # one lane
#
# Env:
#   DOCKER=<cmd>          container runtime (default: docker)
#   SECCOMP=unconfined    relax seccomp; io_uring's syscalls are restricted
#                         under some default profiles, and a lane that cannot
#                         issue them reports UNSUPPORTED-PLATFORM rather than
#                         a false pass
#
# Exit: 0 all lanes green, 1 a lane is RED, 2 environment.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DOCKER=${DOCKER:-docker}
LANE=${1:-}
IMAGE=mojito-sys-linux-lanes

# Pin to the host's native architecture, and remember the machine name the
# container must report back.
case $(uname -m) in
    arm64|aarch64)  PLATFORM=linux/arm64; WANT_MACHINE=aarch64 ;;
    x86_64|amd64)   PLATFORM=linux/amd64; WANT_MACHINE=x86_64 ;;
    *)
        echo "run-linux-lanes.sh: unsupported host architecture $(uname -m)"
        echo "RESULT: ENVIRONMENT"
        exit 2
        ;;
esac

command -v "$DOCKER" >/dev/null 2>&1 || {
    echo "run-linux-lanes.sh: $DOCKER not found."
    echo "RESULT: ENVIRONMENT"
    exit 2
}

if ! "$DOCKER" build --platform "$PLATFORM" -q -t "$IMAGE" \
        -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" >/dev/null 2>&1; then
    echo "run-linux-lanes.sh: image build failed"
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

sec=""
[ -n "${SECCOMP:-}" ] && sec="--security-opt seccomp=$SECCOMP"

# shellcheck disable=SC2086
"$DOCKER" run --rm -i --platform "$PLATFORM" $sec \
    -e "LANE=$LANE" \
    -e "WANT_MACHINE=$WANT_MACHINE" \
    -v "$REPO_ROOT":/src:ro "$IMAGE" bash -s <<'INNER'
set -u

echo "linux lanes: kernel $(uname -r) $(uname -m)"
if [ "$(uname -m)" != "$WANT_MACHINE" ]; then
    echo "run-linux-lanes.sh: container reports $(uname -m), host is"
    echo "  $WANT_MACHINE. This is an EMULATED container (Rosetta/qemu), where"
    echo "  io_uring_setup returns ENOSYS and an io_uring lane would report"
    echo "  UNSUPPORTED-PLATFORM for a reason that has nothing to do with the"
    echo "  code under test. Refusing to run."
    echo "RESULT: ENVIRONMENT"
    exit 2
fi

# /src is read-only; copy its CONTENTS (not the directory) so the host
# tree is never written to and /work is the repo root.
mkdir -p /work && cp -a /src/. /work/ && cd /work
# The host tree may carry a macOS build; start from nothing.
rm -rf build libmojito_sys.dylib libmojito_spike.dylib libmojito_sys.so
mkdir -p build/sys

# Build the native substrate as a Linux shared object. The Makefile's link
# recipe is Mach-O only; the object rules are portable, so the compile loop
# is spelled out here rather than patching a build the host still needs.
for f in $(find native -name '*.c' | sort); do
    o="build/sys/$(printf '%s' "$f" | tr / _).o"
    gcc -O2 -g -fPIC -D_GNU_SOURCE -Inative/include -c "$f" -o "$o" || exit 2
done
for f in $(find native -name '*.S' | sort); do
    o="build/sys/$(printf '%s' "$f" | tr / _).o"
    # The wrong-architecture asm variant is expected to refuse; the right one
    # must build.
    gcc -Inative/include -c "$f" -o "$o" 2>/dev/null || true
done
gcc -shared -o libmojito_sys.so build/sys/*.o 2>/dev/null || exit 2
echo "linux lanes: libmojito_sys.so built ($(nm -D libmojito_sys.so | grep -cE ' T (mjs|ms)_') exported symbols)"
echo ""

saw_red=0
saw_env=0
ran=0
for lane in tests/s6/*/run.sh; do
    [ -x "$lane" ] || continue
    name=$(basename "$(dirname "$lane")")
    if [ -n "$LANE" ] && [ "$LANE" != "$name" ]; then continue; fi
    ran=$((ran + 1))
    printf '== %s\n' "$name"
    st=0
    CC=gcc "$lane" || st=$?
    # A RED lane must win the aggregate over a later ENV one: rc=$? alone
    # (last write wins) let a real defect get silently overwritten by a
    # subsequent lane's ENVIRONMENT exit, which is exactly the "I could not
    # measure read as nothing wrong" failure mode mojito-async#141 targets.
    # Only exit 2 is the documented ENVIRONMENT contract every S6 lane
    # follows (see each lane's own "Exit: 0 all green, 1 RED, 2
    # environment" header); anything else nonzero -- 1, or an off-contract
    # code from a crash or a missing executable -- counts as RED, not ENV,
    # so a lane that segfaults can never report as merely "environment".
    if [ "$st" -eq 2 ]; then
        saw_env=1
    elif [ "$st" -ne 0 ]; then
        saw_red=1
    fi
    echo ""
done
if [ "$ran" -eq 0 ]; then
    echo "run-linux-lanes.sh: no lane matched"
    exit 2
fi
if [ "$saw_red" -eq 1 ]; then
    exit 1
elif [ "$saw_env" -eq 1 ]; then
    exit 2
fi
exit 0
INNER
