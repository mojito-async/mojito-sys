#!/bin/sh
# mojito-sys S6 aggregator — runs every landed lane suite under tests/s6/
# (issue #174: S6 had no aggregator, no Makefile target, and no gate row at
# all before this).
#
# S6 lanes live at two depths at once: iouring_submit, iouring_unmap, epoll
# and iouring sit directly under tests/s6/<lane>/run.sh (C conformance/
# contract lanes against libmojito_sys), while epoll, poller, socket and
# iouring sit one level deeper under tests/s6/io/<lane>/run.sh (Mojo §38.7
# conformance lanes against the packaged dylib) — S1/S2's flat shape and
# S3's domain/lane nesting, both present in the same suite, so discovery
# below covers both depths instead of picking one. A top-level lane and its
# tests/s6/io/ counterpart can share a directory name (epoll, iouring), so
# the matrix label is the FULL path relative to this directory (S3's
# naming, not S1/S2's basename-only one) — otherwise "epoll" and "io/epoll"
# would collide into the same row.
#
# Several of the top-level C lanes are LINUX-ONLY, and some additionally
# need a native kernel with a real epoll/io_uring backend (issues #74-78,
# #162, #163, #167, #169). On any host without that — this macOS worktree
# included — they exit 2, an ENVIRONMENT/UNSUPPORTED-PLATFORM result: not a
# pass and not a failure (mojito-async#141 — "I could not measure" must
# never read as "nothing wrong"). This aggregator gives that its own matrix
# state (ENV) and does NOT count it toward RESULT/failures, so the S6
# battery stays green on a dev host with no real Linux kernel while the
# matrix still shows, honestly, which rows were never actually exercised.
# tests/docker/run-linux-lanes.sh runs the very same lanes for real inside a
# native-arch Linux container, and mojito-sys's own CI wires that in as a
# separate, reported (non-blocking) job for exactly this reason — see
# .github/workflows/ci.yml's suite-s6-linux job.
#
# Usage: tests/s6/run.sh          (or: make test-s6 from the repo root)
#   MOJO=/path/to/mojo and CC=<cc> are passed through to lane suites (each
#   lane defaults them itself; nothing here needs to re-set them).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Lane suites at either depth: tests/s6/<lane>/run.sh or
# tests/s6/<domain>/<lane>/run.sh, sorted for a stable matrix.
lanes=$(CDPATH= cd -- "$SCRIPT_DIR" && find . -mindepth 2 -maxdepth 3 -name run.sh 2>/dev/null | sort)

if [ -z "$lanes" ]; then
    echo "S6: no lane suites landed yet (tests/s6/**/run.sh); all green by default."
    echo ""
    echo "S6 suite matrix"
    echo "  (no lanes)"
    echo ""
    echo "RESULT: all green"
    exit 0
fi

failures=0
envs=0
matrix=""
for lane_sh in $lanes; do
    lane=$(echo "$lane_sh" | sed 's|^\./||; s|/run\.sh$||')
    printf '== %s\n' "$lane"
    out=$("$SCRIPT_DIR/$lane_sh" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        row="$lane PASS"
    elif [ "$status" -eq 2 ]; then
        row="$lane ENV"
        envs=$((envs + 1))
    else
        row="$lane FAIL"
        failures=$((failures + 1))
    fi
    matrix="$matrix$row
"
    printf '%s\n' "$out" | tail -n 4 | sed 's/^/   | /'
done

echo ""
echo "S6 suite matrix"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED ($envs environment-skipped)"
    exit 1
fi
echo "RESULT: all green ($envs environment-skipped)"
exit 0
