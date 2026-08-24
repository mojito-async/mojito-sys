#!/bin/sh
# mojito-sys S0 spike — T8-T14 harness (issues #12).  Part of the full suite:
#   make test            -> tests/spike/run.sh (T1-T7)  + this file (T8-T14)
#   precommit/gate.sh    -> runs selftest, T1-T7, T8-T14, bench
#
# Mirrors the per-test build steps documented in tests/spike/README.md:
# each Mojo driver is AOT-built together with its probe (asm/C helper linked
# into the same executable), then run with the spike dylib findable at
# runtime. T14 is a pure script audit of the dylib.
#
# Exit codes per test binary/script: 0 PASS, 1 RED/FAIL (message says which),
# T14 additionally 2 = dylib not found. This harness maps any nonzero exit to
# FAIL and keeps going; the overall exit is nonzero if any test failed.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
OUT="$SCRIPT_DIR/.build"
DYLIB="$REPO_ROOT/libmojito_spike.dylib"

failures=0
say() { printf '%s\n' "$*"; }

if [ "$(uname -m)" != "arm64" ]; then
    say "ERROR: T8-T14 target macOS arm64 only (CONTRACT.md): $(uname -m) unsupported"
    exit 2
fi
if ! command -v "$CC" >/dev/null 2>&1; then
    say "ERROR: $CC not found; set CC=<compiler>"
    exit 2
fi
if ! command -v "$MOJO" >/dev/null 2>&1; then
    say "ERROR: $MOJO not found; set MOJO=<path-to-mojo>"
    exit 2
fi
if [ ! -f "$DYLIB" ]; then
    say "ERROR: $DYLIB missing; run \`make\` at the repo root first."
    exit 2
fi

mkdir -p "$OUT"

run_driver() { # <name> <probe-source> <driver-source>
    name=$1; probe=$2; driver=$3
    probe_o="$OUT/${name}_probe.o"
    bin="$OUT/$name"
    case "$probe" in
        *.S)  "$CC" -arch arm64 -c "$SCRIPT_DIR/$probe" -o "$probe_o" ;;
        *.c)  "$CC" -arch arm64 -c "$SCRIPT_DIR/$probe" -o "$probe_o" ;;
        *)    say "== $name ERROR: unknown probe kind: $probe"; failures=$((failures + 1)); return ;;
    esac
    if [ $? -ne 0 ]; then
        say "== $name FAIL (probe build $probe)"
        failures=$((failures + 1))
        return
    fi
    if ! "$MOJO" build "$SCRIPT_DIR/$driver" -o "$bin" \
        -Xlinker "$probe_o" 2>"$OUT/$name.build.log"; then
        say "== $name FAIL (driver build $driver)"
        tail -n 8 "$OUT/$name.build.log" | sed 's/^/    | /'
        failures=$((failures + 1))
        return
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" 2>&1)
    st=$?
    if [ $st -eq 0 ]; then
        say "== $name PASS"
    else
        say "== $name FAIL (exit $st)"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/    | /'
        failures=$((failures + 1))
    fi
}

say "== T8-T14 (issues #12) — builds in $OUT"
run_driver t8  t8_gpr_probe.S    t8_gpr_preservation.mojo
run_driver t9  t9_simd_probe.S   t9_simd_preservation.mojo
run_driver t10 t10_align_probe.S t10_stack_alignment.mojo
run_driver t11 t11_tls_probe.S   t11_tls_continuity.mojo
run_driver t12 t12_synth_probe.S t12_synthetic_stack.mojo
run_driver t13 t13_guard_probe.c t13_guard_page.mojo

say "== t14 (runtime audit)"
out=$(MOJITO_SPIKE_DYLIB="$DYLIB" "$SCRIPT_DIR/t14_runtime_audit.sh" 2>&1)
st=$?
if [ $st -eq 0 ]; then
    say "== t14 PASS"
else
    say "== t14 FAIL (exit $st)"
    printf '%s\n' "$out" | tail -n 8 | sed 's/^/    | /'
    failures=$((failures + 1))
fi

say ""
if [ "$failures" -ne 0 ]; then
    say "RESULT: T8-T14 FAILED ($failures)"
    exit 1
fi
say "RESULT: T8-T14 all green"
exit 0