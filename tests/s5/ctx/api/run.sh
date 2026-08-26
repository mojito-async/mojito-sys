#!/bin/sh
# mojito-sys S5.4 — NativeContext Mojo API conformance lane (issue #67).
#
# Runs the §20 `NativeContext` Mojo wrapper (mojito_sys/ctx) against the
# packaged libmojito_sys.dylib under the repo-root package layout:
#   - create with stack reservation + entry/userdata;
#   - capture_current (self-capture);
#   - real context switching between two NativeContexts (A -> B -> main,
#     counter-verified on both legs);
#   - completion hook fired EXACTLY once (entry return -> finish hook);
#   - destroy semantics + DEAD/FINISHED misuse raising loud Mojo errors
#     (wrapper maps the frozen C hard-traps to recoverable raises);
#   - re-capture revival (capture revives destroyed storage, spec §20).
#
# Pure Mojo over the frozen ms_context_* C ABI — ZERO new C symbols.
#
# Usage: tests/s5/ctx/api/run.sh    MOJO=/path/to/mojo
#   Expects to be run from a checkout where `make` works at the repo root.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_FILE="$SCRIPT_DIR/api_conformance.mojo"
TEST_NAME="s5-ctx-api"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (ms_context.c included).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently crashes while lowering modules that mix
# @extern bindings with raising code (precedent: tests/s4/time/*/run.sh);
# retry a bounded number of times, keeping the last output.
status=2
out=""
attempt=0
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$TEST_FILE" 2>&1)
    status=$?
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2 # compiler crash: retry
    fi
done

matrix=""
echo "== $TEST_NAME"
printf '%s\n' "$out" | sed 's/^/   | /'

if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    matrix="$TEST_NAME PASS
"
else
    matrix="$TEST_NAME FAIL
"
fi

echo ""
echo "S5.4 NativeContext API conformance matrix (issue #67)"
printf '%s' "$matrix" | sed 's/^/  /'
if printf '%s' "$matrix" | grep -q "FAIL"; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0