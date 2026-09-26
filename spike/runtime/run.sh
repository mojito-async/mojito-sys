#!/bin/sh
# spike/runtime/run.sh — M1.3 (#126) runtime spike runner: thread entry,
# TLS, and the kqueue/epoll pollers, all driven directly from Mojo.
#
# Builds spike/runtime/oracle.c into a local dylib/so (ad hoc, no Makefile
# change — same convention as spike/abi/run.sh), and on macOS also builds
# tools/migration_baseline/alloc_probe_shim.c (needed only by tls_test.mojo's
# T6 allocation-free measurement), then runs each Mojo test file against
# them via `mojo run -I <this-dir> -Xlinker <dylib(s)>`.
#
# Usage: spike/runtime/run.sh          (or: from the repo root)
#   MOJO=/path/to/mojo   override the Mojo toolchain
#   CC=<cc>              override the C compiler
#
# Prints a PASS/FAIL/ENVIRONMENT matrix and exits nonzero if any lane
# genuinely FAILs (ENVIRONMENT is not a failure — see each test file's own
# header for exactly when it reports that instead of PASS/FAIL).
#
# NOTE ON OUTPUT ORDERING: precommit/run-suite.sh's own run_driver wraps
# THIS whole script's stdout and keeps only the LAST 20 lines for its own
# CI log (same trap spike/abi/run.sh's own header documents, and the same
# reason this script follows its exact structure: only a one-line
# PASS/FAIL/ENVIRONMENT per lane as it runs, full detail held back and
# printed in one block at the very end for any FAILING lane, plus a
# per-lane raw-output dump to .build/<lane>.out and $GITHUB_STEP_SUMMARY).
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BUILD_DIR="$SCRIPT_DIR/.build"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "RESULT: 1 FAILED"
    exit 2
fi

mkdir -p "$BUILD_DIR"

UNAME_S=$(uname -s)
if [ "$UNAME_S" = "Darwin" ]; then
    ORACLE_LIB="$BUILD_DIR/liboracle.dylib"
    ALLOC_LIB="$BUILD_DIR/alloc_probe_shim.dylib"
else
    ORACLE_LIB="$BUILD_DIR/liboracle.so"
    ALLOC_LIB=""
fi

if [ "$UNAME_S" = "Darwin" ]; then
    if ! "$CC" -O2 -g -Wall -Wextra -dynamiclib -o "$ORACLE_LIB" \
         "$SCRIPT_DIR/oracle.c" 2>"$BUILD_DIR/cc.err"; then
        echo "spike/runtime: oracle.c build failed:"
        sed 's/^/  | /' "$BUILD_DIR/cc.err"
        echo "RESULT: 1 FAILED"
        exit 2
    fi
    # alloc_probe_shim.c is macOS-only (dyld interposing); build it here so
    # tls_test.mojo's T6 has a real allocation counter to link against.
    # tls_test.mojo itself comptime-gates every call into it behind
    # CompilationTarget().is_macos(), so this dylib is simply not passed
    # to -Xlinker on non-macOS hosts below.
    if ! "$CC" -dynamiclib -O0 -g \
         "$SCRIPT_DIR/../../tools/migration_baseline/alloc_probe_shim.c" \
         -o "$ALLOC_LIB" 2>"$BUILD_DIR/cc_alloc.err"; then
        echo "spike/runtime: alloc_probe_shim.c build failed:"
        sed 's/^/  | /' "$BUILD_DIR/cc_alloc.err"
        echo "RESULT: 1 FAILED"
        exit 2
    fi
else
    if ! "$CC" -O2 -g -Wall -Wextra -fPIC -shared -D_GNU_SOURCE \
         -o "$ORACLE_LIB" "$SCRIPT_DIR/oracle.c" 2>"$BUILD_DIR/cc.err"; then
        echo "spike/runtime: oracle.c build failed:"
        sed 's/^/  | /' "$BUILD_DIR/cc.err"
        echo "RESULT: 1 FAILED"
        exit 2
    fi
fi

failures=0
matrix=""
failure_detail=""

# run_lane <name> <file>
run_lane() {
    name=$1
    file=$2

    status=2
    out=""
    attempt=0
    # The b2 toolchain intermittently segfaults while lowering modules
    # (precedent: spike/abi/run.sh, tests/s1/memory/vm/run.sh); retry a
    # bounded number of times, keeping the last output.
    while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        if [ -n "$ALLOC_LIB" ] && [ -f "$ALLOC_LIB" ]; then
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" \
                -Xlinker "$ORACLE_LIB" -Xlinker "$ALLOC_LIB" "$file" 2>&1)
        else
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" \
                -Xlinker "$ORACLE_LIB" "$file" 2>&1)
        fi
        status=$?
        if printf '%s' "$out" | grep -q "Stack dump"; then
            status=2 # compiler crash: retry
        fi
    done

    printf '%s\n' "$out" > "$BUILD_DIR/$name.out" 2>/dev/null || true

    if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        echo "== $name PASS (attempt $attempt)"
        matrix="$matrix$name PASS
"
    elif [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: ENVIRONMENT"; then
        echo "== $name ENVIRONMENT (attempt $attempt) — backend unavailable on this host, not a failure"
        matrix="$matrix$name ENVIRONMENT
"
    else
        echo "== $name FAIL (attempt $attempt, exit $status) — detail held for the end"
        matrix="$matrix$name FAIL
"
        failures=$((failures + 1))
        fail_lines=$(printf '%s\n' "$out" | grep -i "FAIL\|error\|Stack dump\|Unhandled exception" | head -n 12)
        failure_detail="$failure_detail
---- $name FAILED (exit $status) — failing checks ----
$fail_lines
---- $name — last 8 lines of raw output ----
$(printf '%s\n' "$out" | tail -n 8)
"
    fi
}

run_lane "thread"          "thread_test.mojo"
run_lane "tls"              "tls_test.mojo"
run_lane "poller-kqueue"    "poller_kqueue_test.mojo"
run_lane "poller-epoll"     "poller_epoll_test.mojo"

echo ""
echo "M1.3 runtime spike matrix (issue #126)"
echo "$matrix" | sed 's/^/  /'

if [ "$failures" -ne 0 ]; then
    printf '%s\n' "$failure_detail"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "## spike/runtime/run.sh FAILED ($failures lane(s))"
            echo '```'
            printf '%s\n' "$failure_detail"
            echo '```'
            for f in "$BUILD_DIR"/*.out; do
                [ -f "$f" ] || continue
                echo "<details><summary>$(basename "$f") — full raw output</summary>"
                echo ""
                echo '```'
                cat "$f"
                echo '```'
                echo "</details>"
            done
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
