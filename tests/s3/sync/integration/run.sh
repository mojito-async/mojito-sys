#!/bin/sh
# mojito-sys S3.6 — cross-primitive integration + phase audits runner
# (issue #62). Closes the S3 phase: drives ALL FOUR sync primitives
# against each other (conformance.mojo) and runs the executable
# repo-convention audits (audit_sync.sh), plus a package-path import
# check for the whole S3 surface.
#
# DEFERRED (issue #62 phase close): the §14 NativeSemaphore
# permit-accounting leg is NOT covered by this suite — no lane, conformance
# row, or audit exists for it repo-wide. Explicitly deferred at the S3
# batch-panel review; tracked by a dedicated follow-up issue (filed
# separately when #62 closes). Do not treat the S3 phase as covering
# semaphores.
#
# Rows:
#   s3-integration-mojo     — bounded buffer 8x8x100k + 50k park/unpark
#                             churn + cross-primitive wrapper decode
#                             (AOT-built per the b2 note in tests/s2);
#   s3-audit-sys5-trio      — every public def carries the SYS-5 trio;
#   s3-audit-static-claims  — no false "b2 lacks @staticmethod" claims;
#   s3-audit-exports        — exports.txt <-> nm exact, ALL S3 symbols;
#   s3-audit-header-frozen  — frozen header append-only vs origin/main;
#   s3-sync-import          — package-path import of the S3 surface.
#
# Prints '<row> PASS/FAIL' lines plus "RESULT: all green"; exits
# nonzero when any row fails. Usage:
#   tests/s3/sync/integration/run.sh    MOJO=/path/to/mojo

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
CC=${CC:-cc}
BUILD_DIR="$SCRIPT_DIR/.build"

TEST_NAME="s3-integration"
TEST_FILE="$SCRIPT_DIR/conformance.mojo"
IMPORT_FILE="$SCRIPT_DIR/import_check.mojo"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    echo "$TEST_NAME RUN-ERROR (toolchain unavailable)"
    exit 2
fi

mkdir -p "$BUILD_DIR"

# Build/rebuild the packaged dylib so this suite always exercises the
# current native sources (also required by the exports audit).
if ! make -C "$REPO_ROOT" libmojito_sys.dylib >"$BUILD_DIR/make.log" 2>&1; then
    echo "ERROR: make libmojito_sys.dylib failed:"
    tail -n 12 "$BUILD_DIR/make.log" | sed 's/^/    | /'
    echo "$TEST_NAME RUN-ERROR (library build failed)"
    exit 2
fi

matrix=""

# ---- cross-primitive conformance (AOT; see run_thread.sh b2 note) -------
BIN="$BUILD_DIR/integration_conformance"
status=2
out=""
attempt=0
t_start=$(date +%s)
while [ $status -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    out=$("$MOJO" build -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" -o "$BIN" "$TEST_FILE" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
        out=$(env DYLD_LIBRARY_PATH="$REPO_ROOT" "$BIN" 2>&1)
        status=$?
    fi
    if printf '%s' "$out" | grep -q "Stack dump"; then
        status=2  # compiler crash: retry
    fi
done
t_end=$(date +%s)

echo "== $TEST_NAME (mojo wrapper)"
printf '%s\n' "$out" | sed 's/^/   | /'
echo "   | wall: $((t_end - t_start))s (CI budget < 60s)"
if [ $status -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: 3/3 PASSED"; then
    matrix="${matrix}s3-integration-mojo PASS
"
else
    matrix="${matrix}s3-integration-mojo FAIL
"
fi

# ---- executable repo-convention audits ------------------------------------
echo "== s3-sync audits"
audit_out=$(sh "$SCRIPT_DIR/audit_sync.sh" "$REPO_ROOT" 2>&1)
audit_status=$?
printf '%s\n' "$audit_out" | sed 's/^/   | /'
for row_name in s3-audit-sys5-trio s3-audit-static-claims s3-audit-exports s3-audit-header-frozen; do
    if printf '%s\n' "$audit_out" | grep -q "^$row_name PASS"; then
        matrix="${matrix}$row_name PASS
"
    else
        matrix="${matrix}$row_name FAIL
"
    fi
done

# ---- import-surface coverage for the package path -------------------------
imp_status=0
imp_out=$("$MOJO" run -I "$REPO_ROOT" -Xlinker "$REPO_ROOT/libmojito_sys.dylib" "$IMPORT_FILE" 2>&1) || imp_status=$?

echo "== s3-sync-import"
printf '%s\n' "$imp_out" | sed 's/^/   | /'
if [ $imp_status -eq 0 ] && printf '%s' "$imp_out" | grep -q "s3-integration-import-ok"; then
    matrix="${matrix}s3-sync-import PASS
"
else
    matrix="${matrix}s3-sync-import FAIL
"
fi

echo ""
echo "S3.6 sync integration + phase audit matrix (issue #62)"
echo "  s3-semaphore-permits DEFERRED (§14 permit-accounting leg; follow-up issue)"
printf '%s' "$matrix" | sed 's/^/  /'
case "$matrix" in
    *FAIL*)
        echo "RESULT: FAILED"
        exit 1
        ;;
esac
echo "RESULT: all green"
exit 0
