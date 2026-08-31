#!/bin/sh
# spike/abi/run.sh — M1.2 (#124) ABI spike runner: struct-layout half,
# libc-call half, and the leaf-module-constraint probe.
#
# Builds spike/abi/oracle.c into a local dylib (ad hoc, no Makefile
# change — same convention as tests/s1/memory/vm/run.sh), then runs each
# Mojo test file against it via `mojo run -I <repo-root>/spike/abi
# -Xlinker <dylib>` (ordinary_frame_test.mojo needs no dylib — every
# symbol it touches is raw libc/OS, no oracle indirection at all).
#
# Usage: spike/abi/run.sh          (or: from the repo root)
#   MOJO=/path/to/mojo   override the Mojo toolchain
#   CC=<cc>              override the C compiler
#
# Prints a PASS/FAIL matrix and exits nonzero if any lane fails.
#
# NOTE ON OUTPUT ORDERING: precommit/run-suite.sh's own run_driver wraps
# THIS whole script's stdout and keeps only the LAST 20 lines for its own
# CI log. A lane's full detail printed immediately after it runs would be
# buried under later lanes' output and lost in CI. So this script instead
# prints only a one-line PASS/FAIL per lane as it runs, and holds a dense
# excerpt (the failing check lines + last few lines of raw output) for
# each FAILING lane back — printing it in one block at the very end,
# right before the final RESULT line, so it is what survives any outer
# truncation. Each lane's COMPLETE raw output is also written to
# .build/<lane>.out for local debugging (gitignored, not part of CI's
# captured log).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BUILD_DIR="$SCRIPT_DIR/.build"
DYLIB="$BUILD_DIR/liboracle.dylib"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "RESULT: 1 FAILED"
    exit 2
fi

mkdir -p "$BUILD_DIR"
if ! "$CC" -O2 -g -Wall -Wextra -dynamiclib -o "$DYLIB" \
     "$SCRIPT_DIR/oracle.c" 2>"$BUILD_DIR/cc.err"; then
    echo "spike/abi: oracle.c build failed:"
    sed 's/^/  | /' "$BUILD_DIR/cc.err"
    echo "RESULT: 1 FAILED"
    exit 2
fi

failures=0
matrix=""
failure_detail=""

# run_lane <name> <file> <needs-dylib: 0|1>
run_lane() {
    name=$1
    file=$2
    needs_dylib=$3

    status=2
    out=""
    attempt=0
    # The b2 toolchain intermittently segfaults while lowering modules
    # (precedent: tests/s1/memory/vm/run.sh, spike/completion/run.sh);
    # retry a bounded number of times, keeping the last output.
    while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
        attempt=$((attempt + 1))
        if [ "$needs_dylib" = "1" ]; then
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" -Xlinker "$DYLIB" "$file" 2>&1)
        else
            out=$(cd "$SCRIPT_DIR" && "$MOJO" run -I "$SCRIPT_DIR" "$file" 2>&1)
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
    else
        echo "== $name FAIL (attempt $attempt, exit $status) — detail held for the end"
        matrix="$matrix$name FAIL
"
        failures=$((failures + 1))
        # precommit/run-suite.sh's own run_driver keeps only the LAST 20
        # lines of this whole script's stdout for its CI log, so a dense
        # "which checks actually failed" excerpt (not the full output,
        # which could be 50-90 lines for one lane alone) is what has to
        # survive that truncation. Grep for FAIL lines specifically, plus
        # the tail of the raw output for any crash/traceback context.
        fail_lines=$(printf '%s\n' "$out" | grep -i "FAIL\|error\|Stack dump\|Unhandled exception" | head -n 12)
        failure_detail="$failure_detail
---- $name FAILED (exit $status) — failing checks ----
$fail_lines
---- $name — last 8 lines of raw output ----
$(printf '%s\n' "$out" | tail -n 8)
"
    fi
}

run_lane "struct-layout"    "struct_layout_test.mojo"   1
run_lane "libc-calls"       "libc_calls_test.mojo"      1
run_lane "ordinary-frame"   "ordinary_frame_test.mojo"  0

echo ""
echo "M1.2 abi spike matrix (issue #124)"
echo "$matrix" | sed 's/^/  /'

if [ "$failures" -ne 0 ]; then
    printf '%s\n' "$failure_detail"
    # CI's raw step log for precommit/gate.sh's full-tier run has been
    # observed to drop most drivers' stdout entirely (confirmed: a run
    # where the ONLY output between "gate tier: full" and the final
    # matrix was the matrix itself, for a step that runs 15+ heavy
    # drivers — not this script's own tail limits, since the fetched log
    # blob was genuinely complete at its own byte length, not truncated
    # by the fetch). $GITHUB_STEP_SUMMARY is a separate, non-log-stream
    # channel GitHub Actions renders directly in the run's UI; write the
    # full per-lane output there too whenever it exists, so a real CI
    # failure's actual detail survives even if the raw log does not.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "## spike/abi/run.sh FAILED ($failures lane(s))"
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
