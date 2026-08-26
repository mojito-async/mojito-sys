#!/bin/sh
# mojito-sys S2.7 — thread/TLS MSVS conformance suite aggregator (#54,
# spec §38.5 L1839–1875).
#
# Executes the two §38.5 sub-suites as per-lane runners, mirroring the
# tests/s2/native/run.sh aggregator pattern:
#   threads/run.sh — create/join, sequential x100, concurrent x32,
#                    return value/error, trampoline, IDs, shutdown drain;
#   tls/run.sh     — isolation, set/get, destructor-once, thread reuse,
#                    TLS across a same-thread context switch.
# Each sub-runner owns its own build/link flags; absent runners are
# reported SKIP so stacked lanes land one at a time. Gate-compatible
# '<name> PASS/FAIL/SKIP(absent)' rows plus a RESULT line:
#     RESULT: all green | RESULT: N FAILED
# Wiring note: this script is the entrypoint #56 flips into the
# make test-s2 chain / precommit gate once S2.7 is green.
#
# Usage: tests/s2/conformance/run.sh   MOJO=/path/to/mojo

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
    printf '%s\n' "$out" | tail -n 6 | sed 's/^/   | /'
}

run s2-conformance-threads threads/run.sh
run s2-conformance-tls    tls/run.sh

printf '\nS2.7 conformance matrix (issue #54)\n%s' "$matrix"
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
