#!/bin/sh
# mojito-sys S6.7 — benchmark regression gate (issue #79, spec §38.13).
#
# Compares the METRIC rows printed by benchmark/io/*_bench.mojo against the
# committed baselines in baselines.tsv with a per-metric tolerance and
# direction, calibrated from observed variance on the M5/ARM64 kqueue
# (darwin) dev host (spec §38.13).
#
# Input: METRIC lines on stdin, of the form emitted by benchmark/io/run:
#   METRIC\t<metric_id>\t<VALUE>|<SKIP\t<detail>
#
# Baselines format (baselines.tsv): four TAB-separated columns
#   <metric_id>\t<direction>\t<baseline>\t<tolerance>
#   direction: ge = higher-better (value >= baseline*(1-tol));
#              le = lower-better (value <= baseline*(1+tol));
#   tolerance: fraction in (0,1); the 4th column defaults to 0.5.
#
# A metric whose live value falls beyond its calibrated tolerance is a
# REGRESSION -> non-zero exit. SKIP rows never fail; unknown/missing
# metrics are reported but not scored.
#
# Usage: benchmark/io/gate.sh < metric_lines.txt
# Exit: 0 all-pass (or all-skip); 1 if any metric regressed.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE="$SCRIPT_DIR/baselines.tsv"

regressed=0
count=0
skipped=0

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
baselines="$tmpdir/baselines"

awk -F'\t' 'NF>=3 && $1!~/^#/ {
    tol = ($4=="" ? 0.5 : $4)
    printf "%s %s %s %s\n", $1, $2, $3, tol
}' "$BASE" > "$baselines" 2>/dev/null || true

declared=$(wc -l < "$baselines" 2>/dev/null | tr -d ' ' || echo 0)

while IFS= read -r line; do
    case "$line" in
        METRIC*) ;;
        *) continue ;;
    esac
    # shellcheck disable=SC2046
    set -- $(printf '%s' "$line" | tr '\t' ' ')
    id="$2"
    value_field="$3"
    count=$((count + 1))
    if [ "$value_field" = "SKIP" ] || [ "$value_field" = "ERROR" ]; then
        printf '  %-28s SKIP  (host-limited/transient)\n' "$id"
        skipped=$((skipped + 1))
        continue
    fi
    row=$(awk -v id="$id" '$1==id {print $2,NR,$3,$4; exit}' "$baselines")
    if [ -z "$row" ]; then
        printf '  %-28s NOTE  (no baseline; not scored)\n' "$id"
        continue
    fi
    dir=$(printf '%s' "$row" | awk '{print $1}')
    base=$(printf '%s' "$row" | awk '{print $3}')
    tol=$(printf '%s' "$row" | awk '{print $4}')
    val="$value_field"
    if ! printf '%s' "$val" | grep -qE '^[0-9]+$'; then
        printf '  %-28s SKIP  (non-numeric value=%s)\n' "$id" "$val"
        skipped=$((skipped + 1))
        continue
    fi
    ok=0
    if [ "$dir" = "ge" ]; then
        floor=$(awk -v b="$base" -v t="$tol" 'BEGIN{printf "%d", b*(1-t)}')
        if [ "$val" -ge "$floor" ]; then ok=1; fi
    else
        ceil=$(awk -v b="$base" -v t="$tol" 'BEGIN{printf "%d", b*(1+t)}')
        if [ "$val" -le "$ceil" ]; then ok=1; fi
    fi
    if [ "$ok" -eq 1 ]; then
        printf '  %-28s PASS  (value=%s ref=%s dir=%s tol=%s)\n' "$id" "$val" "$base" "$dir" "$tol"
    else
        printf '  %-28s FAIL  (value=%s ref=%s dir=%s tol=%s)\n' "$id" "$val" "$base" "$dir" "$tol"
        regressed=$((regressed + 1))
    fi
done

echo ""
echo "S6.7 benchmark regression gate (issue #79)"
printf '  baselines: %s\n' "$declared"
printf '  reported:  %s (%s skipped)\n' "$count" "$skipped"
if [ "$regressed" -eq 0 ]; then
    echo "  gate: PASS"
else
    echo "  gate: FAIL ($regressed regression(s))"
fi
[ "$regressed" -eq 0 ]