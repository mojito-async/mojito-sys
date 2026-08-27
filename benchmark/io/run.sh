#!/bin/sh
# mojito-sys S6.7 — poller + socket-loopback benchmark lane (issue #79,
# spec §38.12 Poller benchmarks + Socket benchmarks, §38.13 regression gates).
#
# Runs both benches (kqueue poller on darwin/BSD; loopback sockets) against
# the packaged libmojito_sys.dylib, feeds the METRIC rows through
# gateway/io/gate.sh against the committed baselines.tsv (documented
# per-metric tolerance + direction, calibrated from observed variance), and
# ends with `RESULT: all green` when nothing regressed.
# Usage: benchmark/io/run.sh     MOJO=/path/to/mojo CC=<cc>
#   Expects to be run from a checkout where `make` works at the repo root.
#
# NOTE: this benchmark/io lane is NOT yet wired into the `make bench` target
# (which currently runs only benchmark/spike/bench_switch.mojo); run it
# directly via ./benchmark/io/run.sh (or `make bench-io` where available).
# It is expected to land in `make bench` once both spikes are reviewed on
# every supported backend.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MOJO=${MOJO:-mojo}
BUILD_DIR="$SCRIPT_DIR/.build"

POLLER_BENCH="$SCRIPT_DIR/poller_bench.mojo"
SOCKET_BENCH="$SCRIPT_DIR/socket_loopback_bench.mojo"
LANE="s6-bench"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$LANE RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so the benches always exercise the
# current native sources (mjs_poller.c, mjs_socket.c included).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$LANE RUN-ERROR (library build failed)"
    exit 2
fi

# The b2 toolchain intermittently segfaults while lowering heavy modules
# (precedent: tests/s4/time/*/run.sh); retry a bounded number of times and
# keep the last output. Each bench also degrades per-section (SKIP rows) on
# host-transient failures, so the suite never aborts mid-way.
metrics=""
for bench in "$POLLER_BENCH" "$SOCKET_BENCH"; do
    out=""
    status=2
    attempt=0
    while [ $status -ne 0 ] && [ $attempt -lt 4 ]; do
        attempt=$((attempt + 1))
        out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$bench" 2>&1)
        status=$?
        if printf '%s' "$out" | grep -q "Stack dump"; then
            status=2 # compiler crash: retry
        fi
    done
    echo "== $bench"
    printf '%s\n' "$out" | sed 's/^/   | /'
    metrics="$metrics
$(printf '%s\n' "$out" | grep '^METRIC')"
done

gate_out=$(printf '%s\n' "$metrics" | sed '/^$/d' | "$SCRIPT_DIR/gate.sh" 2>&1)
gate_status=$?
echo ""
echo "== regression gate"
printf '%s\n' "$gate_out" | sed 's/^/   | /'

if [ $gate_status -ne 0 ]; then
    echo "RESULT: FAILED ($LANE regression)"
    exit 1
fi
echo "RESULT: all green"
exit 0