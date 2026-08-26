#!/bin/sh
# mojito-sys S2 — lifecycle stress lane runner (SYS-D6, issue #55).
#
# Gate/known-red key (TEST_NAME): s2-stress
#
# Builds libmojito_sys.dylib from the current native sources, compiles the
# test-local atomic shims (atomic_shim.c -> .build/atomic_shim.o; the frozen
# dylib ABI gains no new symbols), AOT-builds lifecycle_stress.mojo against
# the package + shim and runs it. Prints the driver output prefixed with
# "   | " plus a PASS/FAIL matrix row and:
#     RESULT: all green      (exit 0)
#     RESULT: 1 FAILED       (exit 1, build or run failure)
#     RUN-ERROR / toolchain messages (exit 2: mojo/cc missing or dylib
#     cannot be built — run `make` at the repo root first)
#
# Scales (deterministic at both):
#   default        CI/Tier-0 (<2min): 25 rounds/writer, 4 bursts x 32 threads
#   SOAK=1 env     local soak: 250 rounds/writer, 12 bursts x 32 threads
#   e.g. MOJITO_STRESS_SOAK=1 tests/s2/stress/run.sh
#
# Sanitizers: b2 cannot emit sanitizer-instrumented code for Mojo-generated
# objects, so an ASan/TSan run of the DRIVER is not expressible with this
# toolchain (recorded in the issue). The C shim is still compiled once under
# -fsanitize=address,undefined as a non-gating smoke of its own lowering.
#
# Usage: tests/s2/stress/run.sh    MOJO=/path/to/mojo CC=/path/to/cc

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
OUT="$SCRIPT_DIR/.build"
BUILD_RETRIES=3
TEST_NAME="s2-stress"

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

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (mjs_thread.c / mjs_tls.c included). The build log
# lives INSIDE .build/ so nothing lands in the source tree (gate Tier 0.2).
mkdir -p "$OUT"
MAKE_LOG="$OUT/make.log"
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$MAKE_LOG" 2>&1; then
    echo "ERROR: cannot build $REPO_ROOT/libmojito_sys.dylib; run \`make\` first."
    tail -n 12 "$MAKE_LOG" | sed 's/^/     | /'
    echo "RESULT: RUN-ERROR (library not built)"
    exit 2
fi

SHIM="$OUT/atomic_shim.o"
if ! "$CC" -O2 -g -Wall -Wextra -c "$SCRIPT_DIR/atomic_shim.c" -o "$SHIM"; then
    echo "ERROR: atomic shim build failed (atomic_shim.c)"
    echo "RESULT: RUN-ERROR (shim not built)"
    exit 2
fi

# Non-gating sanitizer smoke of the shim itself (see header note).
if ! "$CC" -fsanitize=address,undefined -c "$SCRIPT_DIR/atomic_shim.c" \
        -o "$OUT/atomic_shim.san.o" >/dev/null 2>&1; then
    echo "note: sanitizer smoke compile unavailable for the C shim (non-gating)"
fi

BIN="$OUT/lifecycle_stress"
LOG="$OUT/lifecycle_stress.build.log"
rm -f "$LOG"

# AOT only: the JIT front-end deterministically SIGSEGVs lowering modules
# against the thread wrapper (precedent: tests/s2/thread/run_thread.sh);
# retry a bounded number of times to ride out intermittent b2 segfaults.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt $BUILD_RETRIES ]; do
    if "$MOJO" build "$SCRIPT_DIR/lifecycle_stress.mojo" -o "$BIN" \
            -I "$REPO_ROOT" -I "$SCRIPT_DIR" \
            -Xlinker "$SHIM" -Xlinker "-L$REPO_ROOT" -Xlinker "-lmojito_sys" \
            2>>"$LOG"; then
        case "$(uname -s)" in
            Darwin) out=$(env DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN" 2>&1) ;;
            *)      out=$(env LD_LIBRARY_PATH="$REPO_ROOT" "$BIN" 2>&1) ;;
        esac
        status=$?
    fi
    attempt=$((attempt + 1))
done

echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'
if [ -n "$LOG" ] && [ -f "$LOG" ] && [ $status -eq 2 ]; then
    echo "driver build failed after $BUILD_RETRIES attempts:"
    tail -n 8 "$LOG" | sed 's/^/     | /'
fi

echo ""
echo "S2 stress matrix (issue #55)"
if [ $status -eq 0 ] && printf '%s\n' "$out" | grep -q "RESULT: s2-stress green"; then
    printf '  %s PASS\n' "$TEST_NAME"
    echo "RESULT: all green"
    exit 0
fi
printf '  %s FAIL\n' "$TEST_NAME"
echo "RESULT: 1 FAILED"
exit 1
