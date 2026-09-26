#!/bin/sh
# tools/migration_baseline/run_all.sh — M1.1 (#122) verification suite:
# runs every check this issue's acceptance criteria depends on, in --check
# mode (nothing here regenerates committed files; use the individual
# scripts without --check to do that). Each driver prints its own verdict;
# this script aggregates them into one VERDICT block, mirroring
# precommit/run-suite.sh's per-driver reporting shape without touching
# that file (this issue's checks are not wired into the repo-wide gate;
# see the PR body for why).
#
# Usage: tools/migration_baseline/run_all.sh
#   CC=<cc> MOJO=<path-to-mojo>  override the toolchains.
#
# Exit: 0 every check passed; 1 at least one failed.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT" || exit 2

rc=0
run() {
    name=$1
    shift
    echo "== $name"
    if "$@"; then
        echo "VERDICT	$name	PASS"
    else
        echo "VERDICT	$name	FAIL"
        rc=1
    fi
    echo ""
}

run no-todos             ./tools/migration_baseline/check_no_todos.sh
run symbol-inventory      ./tools/migration_baseline/gen_symbol_inventory.sh --check
run abi-layout            ./tools/migration_baseline/run_abi_oracle.sh --check
run alloc-counts          ./tools/migration_baseline/run_alloc_counts.sh --check
run baseline-jsonl-schema python3 ./tools/migration_baseline/validate_baseline_jsonl.py

if [ "$rc" -ne 0 ]; then
    echo "run_all: FAILED"
else
    echo "run_all: all green"
fi
exit "$rc"
