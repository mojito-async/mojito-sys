#!/bin/sh
# mojito-sys S3.6 — executable repo-convention audits (issue #62).
#
# Phase-closing static audits over the WHOLE S3 sync surface, reported
# as conformance rows (one PASS/FAIL line per audit; nonzero exit when
# any audit fails):
#
#   s3-audit-sys5-trio      every public def in mojito_sys/sync/*.mojo
#                           (wrapper modules; externs.mojo is the pure
#                           ABI leaf whose bindings are documented per
#                           block) carries the SYS-5 trio — Blocking /
#                           Allocation / Task-aware / SYS-5 — in its
#                           docblock (# comment block above, or the
#                           struct docstring below).
#   s3-audit-static-claims  no docblock in mojito_sys/sync asserts the
#                           FALSE doctrine that b2 lacks @staticmethod
#                           (b2 supports struct static methods repo-wide;
#                           corrected doctrine #62). Only NEGATIVE
#                           claims are violations.
#   s3-audit-exports        exports.txt <-> nm bidirectional EXACT over
#                           ALL S3 symbols (mjs_mutex_/mjs_condvar_/
#                           mjs_atomic_/mjs_event_/mjs_sem_): every listed
#                           name is exported AND every exported S3 symbol
#                           is listed.
#   s3-audit-header-frozen  native/include/mojito_sys.h is APPEND-ONLY
#                           vs origin/main: no mjs_* declaration present
#                           on main may be missing at HEAD (additions are
#                           free; removals/renames need a new issue).
#
# Usage: tests/s3/sync/integration/audit_sync.sh [REPO_ROOT]
# Requires libmojito_sys.dylib to be built (run.sh does it).

set -u

REPO_ROOT=${1:-$(cd "$(dirname -- "$0")/../../../.." && pwd)}
cd "$REPO_ROOT" || exit 2

failures=0
row() { # <name> <exit-status>
    if [ "$2" -eq 0 ]; then
        printf '%s PASS\n' "$1"
    else
        printf '%s FAIL\n' "$1"
        failures=$((failures + 1))
    fi
}

SYNC_MODULES="mojito_sys/sync/common.mojo mojito_sys/sync/mutex.mojo mojito_sys/sync/condvar.mojo mojito_sys/sync/event.mojo mojito_sys/sync/atomic_wait.mojo mojito_sys/sync/semaphore.mojo"

# ---- 1. SYS-5 trio audit ------------------------------------------------------
# awk walks each file once, buffering lines; on file change (and at END)
# it reports every public def whose docblock context lacks a token.
trio_out=$(awk '
function flush() {
    for (d = 1; d <= nlines; d++) {
        line = buf[d]
        if (line !~ /^[[:space:]]*(pub[[:space:]]+)?(def|fn|struct)[[:space:]]+[A-Za-z_]/) continue
        decl = line
        sub(/^[[:space:]]*(pub[[:space:]]+)?(def|fn|struct)[[:space:]]+/, "", decl)
        sub(/[^A-Za-z0-9_].*$/, "", decl)
        if (decl ~ /^_/) continue
        ctx = ""
        # walk UP over comments, blanks and decorators only
        j = d - 1
        while (j >= 1 && j > d - 46) {
            l = buf[j]
            if (l ~ /^[[:space:]]*#/ || l ~ /^[[:space:]]*$/ || l ~ /^[[:space:]]*@/) {
                ctx = l "\n" ctx
                j--
            } else break
        }
        # struct docstrings live BELOW the decl line; collect until the
        # closing triple quote (a single-line """...""" closes itself)
        if (buf[d + 1] ~ /^[[:space:]]*"""/) {
            k = d + 1
            ctx = ctx buf[k] "\n"
            closed = (buf[k] ~ /""".*"""/) ? 1 : 0
            while (!closed && k + 1 <= nlines && k <= d + 80) {
                k++
                ctx = ctx buf[k] "\n"
                if (buf[k] ~ /"""/) closed = 1
            }
        }
        if (ctx !~ /Blocking/ || ctx !~ /Allocation/ || ctx !~ /Task-aware/ || ctx !~ /SYS-5/)
            printf "%s:%d: %s missing SYS-5 trio\n", curfile, d, decl
    }
    nlines = 0
}
FNR == 1 { if (nlines) flush(); curfile = FILENAME }
{ buf[++nlines] = $0 }
END { if (nlines) flush() }
' $SYNC_MODULES)
if [ -n "$trio_out" ]; then
    printf '%s\n' "$trio_out" | sed 's/^/    | /'
    row s3-audit-sys5-trio 1
else
    row s3-audit-sys5-trio 0
fi

# ---- 2. false @staticmethod doctrine claims ------------------------------------
# b2 SUPPORTS struct static methods (documented convention); any docblock
# claiming otherwise is a false claim. Match negative wording only, so
# positive statements ("b2 supports struct static methods") pass.
negatives=$(grep -HinE 'static[ _-]method' $SYNC_MODULES \
    | grep -iE '\b(no|not|never|cannot|can.t|lacks?|missing|unsupported|unavailable)\b' || true)
if [ -n "$negatives" ]; then
    printf '%s\n' "$negatives" | sed 's/^/    | /'
    row s3-audit-static-claims 1
else
    row s3-audit-static-claims 0
fi

# ---- 3. exports.txt <-> nm bidirectional over ALL S3 symbols --------------------
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
exp_status=1
if [ -f "$DYLIB" ] && command -v nm >/dev/null 2>&1; then
    tmpdir=$(mktemp -d)
    # nm -gU is BSD/LLVM-only; GNU nm needs -g --defined-only. Probe both so
    # the audit is portable; if NEITHER works, fail loudly below rather than
    # silently comparing an empty symbol set.
    if nm -gU "$DYLIB" >/dev/null 2>&1; then
        NM_LIST="nm -gU"
    elif nm -g --defined-only "$DYLIB" >/dev/null 2>&1; then
        NM_LIST="nm -g --defined-only"
    else
        NM_LIST=""
    fi
    if [ -z "$NM_LIST" ]; then
        rm -rf "$tmpdir"
        echo "    | SKIP: no portable nm found (-gU and -g --defined-only both failed)"
    else
        $NM_LIST "$DYLIB" | awk 'NF >= 3 {print $3}' | sed 's/^_//' | sort >"$tmpdir/actual"
        grep -E '^mjs_(mutex_|condvar_|atomic_|event_|sem_)' "$tmpdir/actual" >"$tmpdir/actual_s3"
        sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' tests/s1/pkg/exports.txt \
            | sed 's/[[:space:]]//g' | grep -E '^mjs_(mutex_|condvar_|atomic_|event_|sem_)' | sort >"$tmpdir/expected_s3"
        missing_in_dylib=$(comm -23 "$tmpdir/expected_s3" "$tmpdir/actual_s3")
        unlisted_exports=$(comm -13 "$tmpdir/expected_s3" "$tmpdir/actual_s3")
        if [ -z "$missing_in_dylib" ] && [ -z "$unlisted_exports" ]; then
            exp_status=0
        else
            [ -n "$missing_in_dylib" ] && printf '    | listed but NOT exported: %s\n' \
                "$(echo "$missing_in_dylib" | tr '\n' ' ')"
            [ -n "$unlisted_exports" ] && printf '    | exported but NOT listed: %s\n' \
                "$(echo "$unlisted_exports" | tr '\n' ' ')"
        fi
        rm -rf "$tmpdir"
    fi
else
    echo "    | libmojito_sys.dylib missing or nm unavailable"
fi
row s3-audit-exports $exp_status

# ---- 4. frozen-header append-only vs origin/main ---------------------------------
hdr_status=1
if git rev-parse --verify origin/main >/dev/null 2>&1; then
    # Anchor to DECLARATION lines only (identifier immediately followed by
    # an open paren), skipping comment lines — a doc mention of mjs_foo()
    # inside a /* ... */ block is neither a declaration nor a removal.
    decl_syms() {
        awk '
        {
            t = $0
            sub(/^[[:space:]]+/, "", t)
            if (t ~ /^[*/]/ || t ~ /^\/\//) next   # comment lines
            while (match(t, /mjs_[a-z0-9_]+[[:space:]]*\(/)) {
                s = substr(t, RSTART, RLENGTH)
                sub(/[[:space:]]*\($/, "", s)
                print s
                t = substr(t, RSTART + RLENGTH)
            }
        }' "$1" | sort -u
    }
    git show origin/main:native/include/mojito_sys.h 2>/dev/null \
        | decl_syms /dev/stdin >"$tmpdir/main_decls"
    decl_syms native/include/mojito_sys.h >"$tmpdir/head_decls"
    removed=$(comm -23 "$tmpdir/main_decls" "$tmpdir/head_decls")
    if [ -z "$removed" ]; then
        hdr_status=0
    else
        printf '    | declared on main but MISSING at HEAD (append-only violation): %s\n' \
            "$(echo "$removed" | tr '\n' ' ')"
    fi
    rm -rf "$tmpdir"
else
    echo "    | origin/main unreachable; cannot verify frozen header"
fi
row s3-audit-header-frozen $hdr_status

# ---- summary ----------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
    echo "AUDIT RESULT: $failures FAILED"
    exit 1
fi
echo "AUDIT RESULT: all green"
exit 0
