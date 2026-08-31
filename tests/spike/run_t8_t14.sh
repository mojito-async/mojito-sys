#!/bin/sh
# mojito-sys S0/M1.4 spike — T8-T14 harness (issues #12, #128).  Part of
# the full suite:
#   make test            -> tests/spike/run.sh (T1-T7)  + this file (T8-T14)
#   precommit/gate.sh    -> runs selftest, T1-T7, T8-T14, bench
#
# RE-POINTED (#128): T8-T13 now drive the PRODUCTION
# native/posix/ms_context_aarch64.S (ms_context_switch/ms_context_init),
# statically linked into each Mojo AOT binary -- no dlopen, no dlsym, no
# libmojito_spike.dylib anywhere in this harness anymore. Each probe
# (asm/C helper) is linked directly into the same executable as its Mojo
# driver, exactly like tests/spike/run.sh already does for T1-T7. T14 is a
# script audit; it builds and audits its own minimal artifact (see
# t14_runtime_audit.sh) and needs nothing from this harness beyond being
# invoked.
#
# AOT, NOT `mojo run`: the b2 JIT deterministically traps the production
# v3 context lifecycle's first switch (see tests/spike/run.sh / the
# switch-half PR notes). Every test here is built with `mojo build` and
# the resulting binary executed directly.
#
# RETRY ON A KNOWN, FILED, FLAKY COMPILER CRASH (mojito-sys#202): the same
# intermittent `mojo build` self-crash tests/spike/run.sh already retries
# around can hit these drivers too (observed directly while wiring up
# T13). A build that crashes with the signature that issue documents is
# retried a bounded number of times before this harness calls it a real
# failure.
#
# Exit codes per test binary/script: 0 PASS, 1 RED/FAIL (message says which),
# T14 additionally 2 = build failed. This harness maps any nonzero exit to
# FAIL and keeps going; the overall exit is nonzero if any test failed.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CC=${CC:-cc}
MOJO=${MOJO:-mojo}
BINDING_DIR="$REPO_ROOT/spike/stack_switch"
OUT="$SCRIPT_DIR/.build"
MAX_BUILD_ATTEMPTS=3

failures=0
say() { printf '%s\n' "$*"; }

if [ "$(uname -m)" != "arm64" ]; then
    say "ERROR: T8-T14 target macOS arm64 only (the production ms_context_aarch64.S backend and this harness's probes are aarch64-only): $(uname -m) unsupported"
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

mkdir -p "$OUT"

if ! "$CC" -arch arm64 -O2 -I "$REPO_ROOT/native/include" -c "$REPO_ROOT/native/posix/ms_context.c" -o "$OUT/ms_context.o" 2>"$OUT/ms_context.err"; then
    say "ERROR: failed to build native/posix/ms_context.c:"
    sed 's/^/  /' "$OUT/ms_context.err"
    exit 2
fi
if ! "$CC" -arch arm64 -c "$REPO_ROOT/native/posix/ms_context_aarch64.S" -o "$OUT/ms_context_aarch64.o" 2>"$OUT/ms_context_aarch64.err"; then
    say "ERROR: failed to build native/posix/ms_context_aarch64.S:"
    sed 's/^/  /' "$OUT/ms_context_aarch64.err"
    exit 2
fi

run_driver() { # <name> <probe-source> <driver-source> [needs-ms-context: yes|no]
    name=$1; probe=$2; driver=$3; needs_ctx=${4:-yes}
    probe_o="$OUT/${name}_probe.o"
    bin="$OUT/$name"
    case "$probe" in
        *.S)  "$CC" -arch arm64 -c "$SCRIPT_DIR/$probe" -o "$probe_o" 2>"$OUT/$name.probe.err" ;;
        *.c)  "$CC" -arch arm64 -c "$SCRIPT_DIR/$probe" -o "$probe_o" 2>"$OUT/$name.probe.err" ;;
        *)    say "== $name ERROR: unknown probe kind: $probe"; failures=$((failures + 1)); return ;;
    esac
    if [ $? -ne 0 ]; then
        say "== $name FAIL (probe build $probe)"
        sed 's/^/    | /' "$OUT/$name.probe.err"
        failures=$((failures + 1))
        return
    fi

    if [ "$needs_ctx" = "yes" ]; then
        ctx_linkers="-Xlinker $OUT/ms_context.o -Xlinker $OUT/ms_context_aarch64.o"
    else
        ctx_linkers=""
    fi

    attempt=1
    build_ok=0
    while [ "$attempt" -le "$MAX_BUILD_ATTEMPTS" ]; do
        # shellcheck disable=SC2086
        build_out=$("$MOJO" build -I "$BINDING_DIR" $ctx_linkers -Xlinker "$probe_o" \
            "$SCRIPT_DIR/$driver" -o "$bin" 2>&1)
        if [ $? -eq 0 ]; then
            build_ok=1
            break
        fi
        if printf '%s' "$build_out" | grep -q "Please submit a bug report"; then
            # mojito-sys#202: flaky compiler crash, retry.
            attempt=$((attempt + 1))
            continue
        fi
        break
    done
    if [ "$build_ok" -ne 1 ]; then
        say "== $name FAIL (driver build $driver, after $attempt attempt(s))"
        printf '%s\n' "$build_out" | tail -n 15 | sed 's/^/    | /'
        failures=$((failures + 1))
        return
    fi

    out=$("$bin" 2>&1)
    st=$?
    if [ $st -eq 0 ]; then
        say "== $name PASS"
    else
        say "== $name FAIL (exit $st)"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/    | /'
        failures=$((failures + 1))
    fi
}

say "== T8-T14 (issues #12, #128) — builds in $OUT"
run_driver t8  t8_gpr_probe.S    t8_gpr_preservation.mojo
run_driver t9  t9_simd_probe.S   t9_simd_preservation.mojo
run_driver t10 t10_align_probe.S t10_stack_alignment.mojo
run_driver t11 t11_tls_probe.S   t11_tls_continuity.mojo
run_driver t12 t12_synth_probe.S t12_synthetic_stack.mojo
run_driver t13 t13_guard_probe.c t13_guard_page.mojo no

say "== t14 (runtime audit)"
out=$(CC="$CC" "$SCRIPT_DIR/t14_runtime_audit.sh" 2>&1)
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
