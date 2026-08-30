#!/bin/sh
# precommit/run-suite.sh — per-driver verdict runner for mojito-sys.
#
# Ported from mojito-async's precommit/run-suite.sh (issue mojito-async/
# mojito-async#169: mojito-sys had a gate.sh that scored known-red
# allow-listing per BATTERY, e.g. `s5-tests` covering every S5 lane at
# once — the same shape of hole mojito-async/mojito-async#141 closed there.
# `precommit/gate.sh` grades known-red allow-listing PER DRIVER against
# what this script prints:
#
#     VERDICT<TAB><driver-name><TAB><PASS|RED|FAIL>
#
# (gate.sh reclassifies a FAIL to RED when the driver has a live known-red
# row; this script never claims RED itself, so a row with no matching
# VERDICT line shields nothing — that was mojito-sys#77's actual bug,
# fixed by removing the row rather than the check.)
#
# Every driver runs even when an earlier one fails, so one commit reports
# every red rather than only the first.
#
# Exit codes (the gate treats >=2 as a hard environment failure, 1 as
# TDD-red/test-fail, 0 as all-green):
#   0  every driver green
#   1  at least one driver is RED/FAIL
#   2  toolchain missing or `make` preflight failed (environment)
# Cost tiers (issue #169), selected by precommit/gate.sh via
# MOJITO_GATE_TIER (full | affected | hermetic) and, for "affected",
# MOJITO_GATE_STAGED (newline-separated staged paths). Battery granularity
# here is coarser than mojito-async's per-driver-file scoping (this repo's
# known-red rows are per BATTERY: s1-tests, s5-ctx-api, ...), so "affected"
# runs whichever batteries the diff's directories touch, instead of
# individual files within a battery.
#   hermetic  selftest + no-markers only (both cheap, no real toolchain
#             suite run). For docs-only/hermetic-safe diffs.
#   affected  selftest + no-markers, plus only the batteries whose own
#             tree is in MOJITO_GATE_STAGED. For test-only diffs.
#   full      every battery, unscoped — the default when MOJITO_GATE_TIER
#             is unset (a bare invocation, or CI, which never has anything
#             staged).
set -u

cd "$(git rev-parse --show-toplevel)" || exit 2

MOJO=${MOJO:-mojo}
TIER="${MOJITO_GATE_TIER:-full}"
STAGED="${MOJITO_GATE_STAGED:-}"
rc=0

run_driver() { # <name> <command...>
    name=$1
    shift
    out=$("$@" 2>&1)
    st=$?
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/    | /'
    if [ "$st" -eq 0 ]; then
        printf 'VERDICT\t%s\tPASS\n' "$name"
    else
        printf 'VERDICT\t%s\tFAIL\n' "$name"
        rc=1
    fi
}

# touches <prefix> — true if any staged path starts with <prefix>.
touches() {
    prefix=$1
    result=1
    OLDIFS=$IFS
    IFS='
'
    for p in $STAGED; do
        case "$p" in "$prefix"*) result=0 ;; esac
    done
    IFS=$OLDIFS
    return $result
}

# --- gate self-test — the gate's OWN tripwire test -------------------------
# Runs first and needs no toolchain: it drives precommit/gate.sh inside a
# throwaway sandbox and asserts the gate actually blocks what it claims to
# block. Nothing else in this tree tested the gate before this port, which
# is how a stale `s5-tests` row survived on main unnoticed. Always runs, in
# every tier — the "hermetic" baseline issue #169's fix section calls for.
SELFTEST="precommit/test-gate.sh"
if [ ! -x "$SELFTEST" ]; then
    echo "run-suite.sh: $SELFTEST missing; gate self-test coverage LOST."
    exit 3
fi
"$SELFTEST" || rc=1

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "run-suite.sh: $MOJO not on PATH; set MOJO=<path-to-mojo>"
    exit 2
fi

# Preflight: build both dylibs so a missing artifact is not mistaken for
# TDD red. `make` only builds inside the repo.
if ! make -s >/dev/null 2>&1; then
    echo "run-suite.sh: \`make\` at repo root failed; the dylibs cannot be"
    echo "       produced. This is an environment problem, not a test RED."
    exit 2
fi

# Always: cheap and foundational, in every tier.
run_driver selftest    make selftest
run_driver no-markers  sh -c "! git grep -n -E '^(<<<<<<< |>>>>>>> )' -- native mojito_sys tests benchmark spike"

if [ "$TIER" = "hermetic" ]; then
    exit "$rc"
fi

if [ "$TIER" = "affected" ]; then
    touches "tests/spike/" && { run_driver t1-t7 make test; run_driver t8-t14 ./tests/spike/run_t8_t14.sh; }
    touches "benchmark/" && run_driver bench make bench
    touches "tests/s1/" && run_driver s1-tests make test-s1
    if touches "tests/s2/"; then
        run_driver s2-tests         make test-s2
        run_driver s2-conformance   make test-s2-conformance
        run_driver s2-stress        make test-s2-stress
        run_driver s2-integration   make test-s2-integration
        run_driver s2-pkg           make test-s2-pkg
    fi
    touches "tests/s3/sync/atomic_wait/" && run_driver s3-atomic-wait ./tests/s3/sync/atomic_wait/run.sh
    # Any other S3 path (mutex, condvar, semaphore, event, integration,
    # ...) reruns the whole s3-other battery rather than trying to scope
    # further — same call S5 makes for its own non-api lanes.
    touches "tests/s3/" && run_driver s3-other env MOJITO_SKIP_S3_ATOMIC_WAIT=1 MOJO="$MOJO" ./tests/s3/run.sh
    touches "tests/s6/" && run_driver s6-tests make test-s6
    touches "tests/s5/ctx/api/" && run_driver s5-ctx-api ./tests/s5/ctx/api/run.sh
    # Any other S5 path (ctx/sentinel, ctx/lifecycle, x86, ...) reruns the
    # whole s5-other battery rather than trying to scope further — S5's own
    # lanes already share fixtures within that battery.
    touches "tests/s5/" && run_driver s5-other env MOJITO_SKIP_S5_CTX_API=1 MOJO="$MOJO" ./tests/s5/run.sh
    exit "$rc"
fi

# --- full tier (default) ----------------------------------------------------
run_driver t1-t7            make test
run_driver t8-t14           ./tests/spike/run_t8_t14.sh
run_driver bench            make bench
run_driver s1-tests         make test-s1
run_driver s2-tests         make test-s2
run_driver s2-conformance   make test-s2-conformance
run_driver s2-stress        make test-s2-stress
run_driver s2-integration   make test-s2-integration
run_driver s2-pkg           make test-s2-pkg
# S3 is split into two drivers (issue #176, mirroring S5's split below)
# instead of one `s3-tests` row: `s3-atomic-wait` is the lane that was
# genuinely flaky (fixed by #176, but kept as its own driver so a future
# regression there can't hide behind the rest of S3 again); `s3-other` is
# everything else in S3 (mutex, condvar, semaphore, event, integration)
# and must stay green on its own.
run_driver s3-atomic-wait   ./tests/s3/sync/atomic_wait/run.sh
run_driver s3-other         env MOJITO_SKIP_S3_ATOMIC_WAIT=1 MOJO="$MOJO" ./tests/s3/run.sh
# S5 is split into two drivers (issue #169) instead of one `s5-tests` row:
# `s5-ctx-api` is the one lane that's genuinely red today (tracked by
# mojito-sys#173); `s5-other` is everything else in S5 (ctx sentinel,
# runtime-audit, oracle, lifecycle, x86) and must stay green on its own —
# a real S5 regression anywhere else can no longer hide behind the api
# lane's known-red row the way it could when `s5-tests` covered both.
run_driver s5-ctx-api       ./tests/s5/ctx/api/run.sh
run_driver s5-other         env MOJITO_SKIP_S5_CTX_API=1 MOJO="$MOJO" ./tests/s5/run.sh
# S6 stays a single driver (issue #174), unlike S5's split above: nothing
# under tests/s6/ is known-red today, so there is no lane to carve out of
# it. `make test-s6` itself already turns a lane's ENVIRONMENT result
# (exit 2, no real Linux kernel on this host) into a matrix ENV row rather
# than a failure, so this driver reports PASS on a macOS dev host without
# needing a known-red row of its own — see tests/s6/run.sh's header.
run_driver s6-tests         make test-s6

exit "$rc"
