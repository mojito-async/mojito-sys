#!/bin/sh
# mojito-sys S2 thread-area UNION driver (issues #49/#51/#53).
#
# Executes every S2 thread-area suite present as a per-lane runner:
#   run_thread.sh  (NativeThread wrapper conformance, issue #49)
#   run_tls.sh     (NativeTlsKey conformance incl. spike ctx-switch pair, #51)
#   run_cpu.sh     (CpuInfo/CpuSet conformance w/ host oracle, #53)
# Absent runners are reported SKIP so the gate stays green while stacked
# lanes land one at a time; once all three exist nothing is skipped.
# Each per-lane runner owns its own extra link/env flags.

set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
failures=0
matrix=""

run() { # <name> <script>
    name=$1
    script=$2
    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        matrix="${matrix}${name} SKIP(absent)
"
        printf '== %s SKIP (runner not landed yet)\n' "$name"
        return 0
    fi
    out=$("$SCRIPT_DIR/$script" 2>&1)
    status=$?
    if [ "$status" -eq 0 ]; then
        matrix="${matrix}${name} PASS
"
    else
        matrix="${matrix}${name} FAIL
"
        failures=$((failures + 1))
    fi
    printf '%s\n' "$out" | tail -n 4 | sed 's/^/   | /'
}

run s2-thread-mojo run_thread.sh
run s2-tls-mojo    run_tls.sh
run s2-cpu-mojo    run_cpu.sh

printf '\nS2 thread-area matrix\n%s' "$matrix"
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
