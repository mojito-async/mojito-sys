#!/bin/sh
# mojito-sys S6.1/S1 — io handle suite (issues #73 + #42).
#
# Runs tests/s1/io/handles/handles_test.mojo against the platform libc
# (no mojito dylib).  Prints a PASS/FAIL matrix and exits nonzero on any
# failure.
#
# Usage: tests/s1/io/handles/run.sh
#   MOJO=/path/to/mojo overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
MOJO=${MOJO:-mojo}
PKG_ROOT="$REPO_ROOT"

if ! command -v "$MOJO" >/dev/null 2>&1; then
    echo "ERROR: mojo not found on PATH; set MOJO=<path-to-mojo>"
    exit 2
fi

# m-checks (issue #42): the fd ownership wrappers live under
# mojito_sys/io/handle.mojo and are referenced nowhere via abi paths.
#   1. a single line mentioning the abi.handles path together with a
#      migrated fd-wrapper symbol is stale;
#   2. a MULTI-LINE import from mojito_sys.abi.handles is stale outright
#      (post-cutover the sole legal reference is a single-line
#      OpaqueNativeHandle import);
#   3. the abi/ tree must not define the wrappers, the close binding, or
#      the sentinel.
m_abi=$(git -C "$REPO_ROOT" grep -nE 'abi\.handles' -- mojito_sys tests benchmark native 2>/dev/null | grep -E '(OwnedFd|BorrowedFd|ms_close|NO_FD)' || true)
m_multi=$(git -C "$REPO_ROOT" grep -nE 'from mojito_sys\.abi\.handles import \($' -- mojito_sys tests benchmark native 2>/dev/null | sed 's/^/MULTILINE-IMPORT /' || true)
m_defs=$(git -C "$REPO_ROOT" grep -nE '^struct (OwnedFd|BorrowedFd)\b|^comptime NO_FD|^@extern\("close"\)' -- mojito_sys/abi 2>/dev/null | sed 's/^/STALE-DEF /' || true)
m_io=$(git -C "$REPO_ROOT" grep -cE '^struct (OwnedFd|BorrowedFd)' -- mojito_sys/io/handle.mojo 2>/dev/null | cut -d: -f2)
[ -z "$m_io" ] && m_io=0
if [ -n "$m_abi" ] || [ -n "$m_multi" ] || [ -n "$m_defs" ]; then
    echo "m_abi_paths_gone: FAIL"
    printf '%s\n%s\n%s\n' "$m_abi" "$m_multi" "$m_defs" | sed '/^$/d;s/^/  | /'
else
    echo "m_abi_paths_gone: PASS"
fi
if [ "$m_io" != "2" ]; then
    echo "m_wrappers_in_io: FAIL"
else
    echo "m_wrappers_in_io: PASS"
fi

out=$("$MOJO" run -I "$PKG_ROOT" "$SCRIPT_DIR/handles_test.mojo" 2>&1)
status=$?

echo ""
echo "S6.1/S1 io handle matrix (issues #73 + #42):"

# The test emits its own t1..t8 + RESULT rows; echo them verbatim.
printf '%s\n' "$out" | grep -E '^(t[0-9]+_|RESULT)' | sed 's/^/  /'

if printf '%s' "$out" | grep -q 'RESULT: all green' && [ -z "$m_abi" ] && [ -z "$m_multi" ] && [ -z "$m_defs" ] && [ "$m_io" = "2" ]; then
    echo "RESULT: all green"
    exit 0
fi
if printf '%s' "$out" | grep -q 'FAIL'; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: toolchain error (exit=$status)"
printf '%s\n' "$out" | tail -n 12 | sed 's/^/  | /'
exit 1
