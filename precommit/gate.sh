#!/bin/sh
# mojito-sys pre-commit gate — runs locally before every commit.
#
# Tier 0: structural validators.  Always run; block on failure.
# Tier 1: precommit/run-suite.sh, scored PER DRIVER against
#         precommit/known-red.tsv (issue #169 — ported from mojito-async's
#         gate.sh, which mojito-async/mojito-async#141 hardened after a
#         single blanket `suite` row masked a real use-after-free there).
#         Before this port, mojito-sys's known-red rows were matched with a
#         bare `grep`: no closed-issue check, no staleness horizon, no
#         format validation, and a row that matched no check name (like
#         mojito-sys#77's `s6-completion-probe`) silently shielded nothing
#         while looking like it did. All of that is fixed here.
#
# Env:
#   MOJITO_GATE_FAST=1     skip the suite step entirely (Tier 0 only).
#   MOJITO_GATE_TIER=<t>   force full|affected|hermetic instead of the
#                          diff-based default below.
#   MOJO=</path/to/mojo>  override the Mojo toolchain.
#
# Cost tiers (issue #169): the tier is picked from what's actually staged,
# UNLESS MOJITO_GATE_TIER overrides it:
#   - nothing staged (a bare invocation, or CI, which never has anything
#     staged) -> full.
#   - every staged path is doc/hermetic-safe (*.md, docs/**) -> hermetic
#     (selftest + no-markers only; the toolchain suite doesn't run).
#   - every staged path is test-only (tests/**, benchmark/**, or the
#     known-red.tsv allow-list itself) -> affected (only the batteries the
#     diff's directories touch).
#   - anything else (native/, mojito_sys/, Makefile, the gate scripts
#     themselves, or a mix) -> full.
# precommit/run-suite.sh does the actual tier-scoped work; this only
# classifies and exports MOJITO_GATE_TIER/MOJITO_GATE_STAGED for it.
#
# Host rules (same as claude/OX agents on this host):
#   - This gate NEVER deletes or modifies anything outside the workspace; it
#     only builds inside the repo and runs the project's own test suites.
#   - No staged rename/delete outside workspace/ can pass through this gate;
#     it is a peer of the AGENTS.md rules, not a replacement.
set -u

cd "$(git rev-parse --show-toplevel)" || exit 2

GATE_DIR="$PWD/precommit"
KNOWN_RED="$GATE_DIR/known-red.tsv"
FAST="${MOJITO_GATE_FAST:-0}"
failures=0

classify_tier() {
    staged=$(git diff --cached --name-only 2>/dev/null || true)
    if [ -z "$staged" ]; then
        printf '%s' "$staged"
        echo full
        return
    fi
    hermetic_only=1
    test_only=1
    OLDIFS=$IFS
    IFS='
'
    for f in $staged; do
        case "$f" in
            *.md|docs/*) ;;
            *) hermetic_only=0 ;;
        esac
        case "$f" in
            tests/*|benchmark/*|precommit/known-red.tsv|*.md|docs/*) ;;
            *) test_only=0 ;;
        esac
    done
    IFS=$OLDIFS
    printf '%s\n' "$staged"
    if [ "$hermetic_only" = 1 ]; then
        echo hermetic
    elif [ "$test_only" = 1 ]; then
        echo affected
    else
        echo full
    fi
}

# classify_tier prints the staged-file list (possibly empty) followed by a
# final line naming the tier; the last line is the tier, everything before
# it is MOJITO_GATE_STAGED.
_classify_out=$(classify_tier)
MOJITO_GATE_STAGED=$(printf '%s\n' "$_classify_out" | sed '$d')
_auto_tier=$(printf '%s\n' "$_classify_out" | tail -n1)
export MOJITO_GATE_STAGED
export MOJITO_GATE_TIER="${MOJITO_GATE_TIER:-$_auto_tier}"

say() { printf '%s\n' "$*"; }
say "gate tier: $MOJITO_GATE_TIER"

# ---------------------------------------------------------------- Tier 0 ----
ws_errors=$(git diff --cached --check 2>&1)
if [ -n "$ws_errors" ]; then
    say "Tier 0 FAIL: whitespace errors in staged diff:"
    printf '%s\n' "$ws_errors" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

blocked=$(git diff --cached --name-only \
    | grep -E '(^|/)(build|\.build)/|\.(dylib|o|a|pyc|class|tmp|swp)$|\.DS_Store' || true)
if [ -n "$blocked" ]; then
    say "Tier 0 FAIL: build artifacts / junk must not be committed:"
    printf '%s\n' "$blocked" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

conflicts=$(git grep --cached -n -E '^(<<<<<<< |>>>>>>> )' -- \
    '*.mojo' '*.c' '*.S' '*.h' '*.sh' '*.md' '.gitignore' '*.yml' '*.yaml' '*.json' '*.toml' 2>/dev/null || true)
if [ -n "$conflicts" ]; then
    say "Tier 0 FAIL: unresolved conflict markers in staged content:"
    printf '%s\n' "$conflicts" | sed 's/^/  | /'
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------- Tier 1 ----
# Allow-listing is scored PER DRIVER (issue #169, following mojito-async/
# mojito-async#141's design), where "driver" is whatever
# precommit/run-suite.sh names in its own VERDICT line — a whole battery in
# this repo (`s1-tests`, `bench`, ...), split finer only where #169 found a
# reason to (`s5-ctx-api` vs `s5-other`; see run-suite.sh). That is coarser
# than mojito-async's per-test-file granularity, but it is not the hole
# #141 fixed there: run-suite.sh never emits ONE line covering the whole
# tree, so no single row can shield an unrelated failure the way the old
# `s5-tests` row could hide either of two different S5 lanes going red.
#
#     VERDICT<TAB><driver-name><TAB><PASS|RED|FAIL>
#
# and precommit/known-red.tsv carries one row per intentionally-red driver:
#
#     <driver-name><TAB><tracking-issue-url><TAB><yyyy-mm-dd added>
#
# A row is honoured only while it is WELL-FORMED, its tracking issue is
# OPEN, and it is younger than the staleness horizon.  Before this port the
# file held rows matched by a bare grep with none of those checks: one
# (`s5-tests`) pointed at a CLOSED issue (mojito-sys#67) and masked a live
# `api-mojo` conformance failure; another (`s6-completion-probe`) pointed
# at a different closed issue and matched no check name at all, so it
# shielded nothing while looking like a legitimate row. Both are gone.
RED_MAX_AGE_DAYS=${MOJITO_GATE_RED_MAX_AGE_DAYS:-30}

# days_between <yyyy-mm-dd> <yyyy-mm-dd> — portable across BSD/GNU date by
# doing the arithmetic in awk (Julian day number) instead of shelling out to
# a `date` whose flags differ per platform.
days_between() {
    awk -v a="$1" -v b="$2" '
        function jdn(y, m, d,   aa, yy, mm) {
            aa = int((14 - m) / 12); yy = y + 4800 - aa; mm = m + 12 * aa - 3
            return d + int((153 * mm + 2) / 5) + 365 * yy + int(yy / 4) \
                   - int(yy / 100) + int(yy / 400) - 32045
        }
        BEGIN {
            split(a, x, "-"); split(b, y, "-")
            print jdn(y[1] + 0, y[2] + 0, y[3] + 0) - jdn(x[1] + 0, x[2] + 0, x[3] + 0)
        }'
}

# issue_state <url> — OPEN / CLOSED / UNKNOWN.  UNKNOWN when the row does not
# point at a github.com issue, `gh` is absent, or the query fails; the gate
# then NOTEs rather than blocks, so an offline commit still works.  Set
# MOJITO_GATE_REQUIRE_ISSUE_CHECK=1 (CI does) to make UNKNOWN a failure.
issue_state() {
    case "$1" in
        https://github.com/*/issues/[0-9]*) ;;
        *) echo UNKNOWN; return ;;
    esac
    rest=${1#https://github.com/}
    owner=${rest%%/*}; rest=${rest#*/}
    repo=${rest%%/*};  rest=${rest#*/}
    num=${rest#issues/}
    command -v gh >/dev/null 2>&1 || { echo UNKNOWN; return; }
    st=$(gh api "repos/$owner/$repo/issues/$num" --jq .state 2>/dev/null) || { echo UNKNOWN; return; }
    case "$st" in
        open)   echo OPEN ;;
        closed) echo CLOSED ;;
        *)      echo UNKNOWN ;;
    esac
}

# --- validate the allow-list itself ----------------------------------------
# Rows that survive this land in $LIVE_ROWS, one driver name per line; a row
# that does not survive is REPORTED and does not shield anything.
TODAY=$(date +%Y-%m-%d)
LIVE_ROWS=""      # newline-separated driver names whose row survived validation

if [ -f "$KNOWN_RED" ]; then
    while IFS= read -r row; do
        case "$row" in ''|'#'*) continue ;; esac
        rname=$(printf '%s' "$row" | cut -f1)
        rurl=$(printf '%s' "$row" | cut -f2)
        rdate=$(printf '%s' "$row" | cut -f3)
        bad=""
        case "$rname" in
            ''|full|affected|hermetic)
                bad="not a driver name: allow-listing it disarms the gate" ;;
        esac
        if [ -z "$bad" ]; then
            case "$rurl" in
                http://*|https://*) ;;
                *) bad="second field must be a tracking-issue URL (got '$rurl')" ;;
            esac
        fi
        if [ -z "$bad" ]; then
            case "$rdate" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
                *) bad="third field must be the yyyy-mm-dd the row was added (got '$rdate')" ;;
            esac
        fi
        if [ -z "$bad" ]; then
            age=$(days_between "$rdate" "$TODAY")
            if [ "$age" -lt 0 ]; then
                bad="date in the future (got '$rdate'): backdate is not a valid age"
            elif [ "$age" -gt "$RED_MAX_AGE_DAYS" ]; then
                bad="added $rdate, $age days ago (horizon $RED_MAX_AGE_DAYS): a TDD red this old is not a red, it is a defect"
            fi
        fi
        if [ -z "$bad" ]; then
            state=$(issue_state "$rurl")
            if [ "$state" = "CLOSED" ]; then
                bad="tracking issue is CLOSED ($rurl)"
            elif [ "$state" = "UNKNOWN" ] && [ "${MOJITO_GATE_REQUIRE_ISSUE_CHECK:-0}" = "1" ]; then
                bad="tracking issue state could not be verified ($rurl)"
            elif [ "$state" = "UNKNOWN" ]; then
                say "known-red NOTE: could not verify issue state for '$rname' ($rurl); row honoured"
            fi
        fi
        if [ -n "$bad" ]; then
            say "Tier 1 FAIL: known-red row '$rname' refused: $bad"
            failures=$((failures + 1))
        else
            LIVE_ROWS="$LIVE_ROWS$rname
"
        fi
    done < "$KNOWN_RED"
fi

is_known_red() { printf '%s' "$LIVE_ROWS" | grep -qxF "$1"; }

# --- run the suite and score it PER DRIVER ---------------------------------
run_suite_check() {
    out=$("$GATE_DIR/run-suite.sh" 2>&1)
    st=$?
    verdicts=$(printf '%s\n' "$out" | grep '^VERDICT	' || true)

    if [ "$st" -ge 2 ]; then
        # The suite never ran: nothing was measured, so nothing can be
        # allow-listed.  "I could not look" must never read as "nothing
        # wrong".
        printf '%-38s FAIL (exit %s: environment/harness error, never allow-listable)\n' suite "$st"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/    | /'
        failures=$((failures + 1))
        return
    fi

    if [ -z "$verdicts" ]; then
        if [ "$st" -eq 0 ]; then
            printf '%-38s PASS (no per-driver verdicts emitted)\n' suite
        else
            printf '%-38s FAIL (exit %s and no VERDICT rows: the failure cannot be attributed to a driver, so it cannot be allow-listed)\n' suite "$st"
            printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'
            failures=$((failures + 1))
        fi
        return
    fi

    npass=0; nred=0; nfail=0
    OLDIFS=$IFS
    IFS='
'
    for v in $verdicts; do
        dname=$(printf '%s' "$v" | cut -f2)
        dstat=$(printf '%s' "$v" | cut -f3)
        if [ "$dstat" = "PASS" ]; then
            npass=$((npass + 1))
        elif is_known_red "$dname"; then
            printf '%-38s RED (known-red, TDD)\n' "$dname"
            nred=$((nred + 1))
        else
            printf '%-38s FAIL\n' "$dname"
            nfail=$((nfail + 1))
        fi
    done
    IFS=$OLDIFS

    if [ "$nfail" -ne 0 ]; then
        printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'
        failures=$((failures + nfail))
    fi
    printf '%-38s %s (%s pass, %s known-red, %s fail)\n' suite \
        "$([ "$nfail" -eq 0 ] && echo PASS || echo FAIL)" "$npass" "$nred" "$nfail"

    if [ "$st" -ne 0 ] && [ "$nfail" -eq 0 ] && [ "$nred" -eq 0 ]; then
        printf '%-38s FAIL (exit %s with every driver PASS: unattributed failure)\n' suite "$st"
        printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'
        failures=$((failures + 1))
    elif [ "$st" -ne 0 ] && [ "$nfail" -eq 0 ] && [ "$nred" -gt 0 ]; then
        printf 'NOTE %-34s suite exited %s with %s known-red driver(s) and 0 unlisted failures; verify no unattributed failure is hidden\n' suite "$st" "$nred"
    fi
}

if [ "$FAST" != "1" ]; then
    if [ -x "$GATE_DIR/run-suite.sh" ]; then
        run_suite_check
    else
        say "Tier 1 FAIL: precommit/run-suite.sh missing; the gate enforces nothing."
        failures=$((failures + 1))
    fi
fi

# ---------------------------------------------------------------- summary ----
if [ "$failures" -ne 0 ]; then
    say ""
    say "GATE FAILED ($failures issue(s))."
    say "  - Unexpected test failure? Fix the code. After the change the"
    say "    commit may proceed."
    say "  - Intentional TDD red? Add a row to precommit/known-red.tsv:"
    say "      <driver-name><TAB><issue-url><TAB>$(date +%Y-%m-%d)"
    say "    then remove the row once the driver goes green."
    say "  - Emergency escape hatch: git commit --no-verify (see"
    say "    precommit/README.md for why this should stay rare)."
    exit 1
fi
say "gate: all checks passed"
exit 0
