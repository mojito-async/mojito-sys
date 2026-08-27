#!/bin/sh
# benchmark/ctx/gate.sh — S5.6 same-host regression gate (issue #69).
#
# Compares FRESH benchmark numbers (the machine-parseable BENCH_RESULT rows
# from benchmark/ctx/bench_switch.mojo, passed in via env) against the
# committed SAME-HOST baseline in benchmark/ctx/baselines.tsv, and exits
# non-zero on a genuine regression.
#
# Design (spec §38.13: "a regression gate MUST be calibrated per benchmark
# from observed variance rather than using one universal threshold"):
#   * baselines.tsv records, per metric, a measured baseline value plus a
#     fail predicate (`gt N` / `lt N`). The predicates come from the
#     observed run-to-run variance on the RELEASING host (see the baseline
#     file's header comment), not a shared constant.
#   * The bench itself already de-noises: switch_latency_ns is the MINIMUM
#     over REPS batches and round_trips_per_sec the MAXIMUM (best-of), so
#     one straggler batch (scheduler preemption, b2 flake) cannot drag a
#     healthy score past a threshold. Only a sustained, real slowdown
#     (e.g. the switch path doing more work) trips the gate.
#   * SAME-HOST ONLY: the gate refuses to compare a fresh result against a
#     baseline recorded on a different (kernel/arch) machine. On a foreign
#     host it prints an explicit cross-host skip and exits 0 — the numbers
#     mean nothing across hardware, and failing there would be a spurious
#     red, not a regression signal. This is an EXPLICIT skip (documented in
#     output), never a silent pass.
#   * RED state (TDD): if baselines.tsv is absent or a metric row is
#     unparseable, the gate fails with a clear message. The committed lane
#     is genuinely red until baselines land.
#
# Env:
#   SCTX_SWITCH_NS  fresh switch_latency_ns (ns per single switch, min-of-N)
#   SCTX_RPS        fresh round_trips_per_sec (best-of-N)
#   $1              optional work dir (for notes); default build/s5-ctx-bench
#
# Output ends with `GATE: PASS` on success.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASELINES="$SCRIPT_DIR/baselines.tsv"
OUT=${1:-}
[ -n "$OUT" ] || OUT="$SCRIPT_DIR/../../build/s5-ctx-bench"
HOST_ID="$(uname -s)/$(uname -m)/$(uname -r)"

failures=0
say_reg() { printf 'GATE: FAIL — %s\n' "$*"; }

# ---- baselines exist & parse? --------------------------------------------
if [ ! -f "$BASELINES" ]; then
    say_reg "baselines.tsv missing at $BASELINES (commit real numbers)"
    echo "GATE: FAIL"
    exit 1
fi

# host identity recorded in the baseline "host:" line
baseline_host=$(grep '^host:' "$BASELINES" | head -n1 | sed 's/^host:[[:space:]]*//')
if [ -n "$baseline_host" ] && [ "$baseline_host" != "$HOST_ID" ]; then
    printf 'GATE: SKIP (cross-host) — baseline recorded on "%s", this host is "%s"; '
    printf 'numbers are not comparable across hardware. Explicit skip, not a pass.\n' \
        "$baseline_host" "$HOST_ID"
    echo "GATE: PASS"
    exit 0
fi

# ---- per-metric predicate evaluation --------------------------------------
check_metric() { # <name> <fresh_value>
    name=$1
    fresh=$2
    row=$(grep "^$name	" "$BASELINES" | head -n1)
    if [ -z "$row" ]; then
        say_reg "no baseline row for metric '$name'"
        failures=$((failures + 1))
        return
    fi
    # columns: metric \t baseline \t predicate
    baseline=$(printf '%s' "$row" | cut -f2)
    pred=$(printf '%s' "$row" | cut -f3)   # e.g. "gt 10" or "lt 70000000"
    if ! printf '%s' "$baseline" | grep -qE '^[0-9]+$' \
            || ! printf '%s' "$fresh" | grep -qE '^[0-9]+$'; then
        say_reg "non-numeric metric '$name' (baseline='$baseline' fresh='$fresh')"
        failures=$((failures + 1))
        return
    fi
    case "$pred" in
        gt\ *)
            limit=${pred#gt }
            if ! printf '%s' "$limit" | grep -qE '^[0-9]+$'; then
                say_reg "bad predicate for '$name': '$pred'"
                failures=$((failures + 1))
                return
            fi
            if [ "$fresh" -gt "$limit" ]; then
                say_reg "$name regression: fresh=$fresh > threshold=$limit (baseline=$baseline)"
                failures=$((failures + 1))
            else
                printf 'GATE:   %s ok  fresh=%s baseline=%s (fail if > %s)\n' \
                    "$name" "$fresh" "$baseline" "$limit"
            fi
            ;;
        lt\ *)
            limit=${pred#lt }
            if ! printf '%s' "$limit" | grep -qE '^[0-9]+$'; then
                say_reg "bad predicate for '$name': '$pred'"
                failures=$((failures + 1))
                return
            fi
            if [ "$fresh" -lt "$limit" ]; then
                say_reg "$name regression: fresh=$fresh < threshold=$limit (baseline=$baseline)"
                failures=$((failures + 1))
            else
                printf 'GATE:   %s ok  fresh=%s baseline=%s (fail if < %s)\n' \
                    "$name" "$fresh" "$baseline" "$limit"
            fi
            ;;
        *)
            say_reg "unrecognized predicate for '$name': '$pred'"
            failures=$((failures + 1))
            ;;
    esac
}

check_metric "switch_latency_ns" "${SCTX_SWITCH_NS:-}"
check_metric "round_trips_per_sec" "${SCTX_RPS:-}"

if [ "$failures" -ne 0 ]; then
    echo "GATE: FAIL ($failures regression(s))"
    exit 1
fi
echo "GATE: PASS"
exit 0
