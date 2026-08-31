#!/bin/sh
# tools/migration_baseline/check_no_todos.sh — M1.1 (#122) acceptance check:
# "every inventory above is complete with no TODO placeholders."
#
# Verifies:
#   1. docs/mojito-sys_MOJO_MIGRATION_SPEC.md and MOJO_MIGRATION_BASELINE.md
#      both exist at the repo root / docs/ (the two halves #122 lands).
#   2. Neither file contains a placeholder marker: TODO, TBD, FIXME, XXX,
#      "PLACEHOLDER", "<fill in>", "???" — the exact strings a half-finished
#      inventory row would carry instead of a real, measured value.
#   3. Neither file is a stub: each must clear a minimum line-count floor,
#      so an empty-but-technically-present file cannot pass by omission.
#
# This is a RED-first check (TDD, issue #122 process note): it fails today
# because neither document exists yet. It goes green only once both are
# written with no placeholders left in them.
#
# Usage: tools/migration_baseline/check_no_todos.sh
# Exit: 0 all clear; 1 a placeholder or missing/stub file was found.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

SPEC="$REPO_ROOT/docs/mojito-sys_MOJO_MIGRATION_SPEC.md"
BASELINE="$REPO_ROOT/MOJO_MIGRATION_BASELINE.md"
MIN_LINES=200

failures=0

# Markers that mean "this row is not actually filled in yet." Case-
# sensitive on purpose: "TBD" the placeholder is not the same string as an
# incidental lowercase "tbd" inside prose, and none of these words has a
# legitimate reason to appear in a finished baseline/spec document.
MARKERS='TODO|TBD|FIXME|XXX|PLACEHOLDER|<fill in>|\?\?\?'

check_file() {
    f=$1
    label=$2
    if [ ! -f "$f" ]; then
        echo "FAIL: $label missing: $f"
        failures=$((failures + 1))
        return
    fi
    lines=$(wc -l <"$f" | tr -d ' ')
    if [ "$lines" -lt "$MIN_LINES" ]; then
        echo "FAIL: $label has only $lines lines (< $MIN_LINES floor): $f"
        failures=$((failures + 1))
    fi
    hits=$(grep -nE "$MARKERS" "$f" || true)
    if [ -n "$hits" ]; then
        echo "FAIL: $label contains placeholder marker(s):"
        printf '%s\n' "$hits" | sed 's/^/    | /'
        failures=$((failures + 1))
    fi
    if [ -z "$hits" ] && [ "$lines" -ge "$MIN_LINES" ] && [ -f "$f" ]; then
        echo "OK: $label ($lines lines, no placeholder markers)"
    fi
}

check_file "$SPEC" "docs/mojito-sys_MOJO_MIGRATION_SPEC.md"
check_file "$BASELINE" "MOJO_MIGRATION_BASELINE.md"

if [ "$failures" -ne 0 ]; then
    echo ""
    echo "check_no_todos: FAIL ($failures issue(s))"
    exit 1
fi
echo "check_no_todos: PASS"
exit 0
