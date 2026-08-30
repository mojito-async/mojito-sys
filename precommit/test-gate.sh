#!/bin/sh
# precommit/test-gate.sh — self-test for the pre-commit gate.
#
# Ported from mojito-async's precommit/test-gate.sh (issue mojito-async/
# mojito-async#169: this repo had NO test for its own gate, the same gap
# mojito-async/mojito-async#141 found and fixed there — nothing in this
# tree proved the gate actually blocked what it claimed to block, which is
# exactly how a stale known-red row (mojito-sys#67, closed the moment the
# api-mojo lane it was still masking merged) survived unnoticed).
#
# This script drives the REAL precommit/gate.sh inside a throwaway git
# sandbox with a stubbed run-suite.sh, so each case is hermetic and fast (no
# Mojo, no dylibs, no real suite run), and asserts on the gate's OBSERVABLE
# behaviour: its exit status and what it printed.
#
# The verdict protocol the per-driver cases assume is one line per driver on
# the suite runner's stdout:
#
#     VERDICT<TAB><driver-name><TAB><PASS|RED|FAIL>
#
# and an allow-list row of three TAB-separated fields:
#
#     <driver-name><TAB><tracking-issue-url><TAB><yyyy-mm-dd added>
#
# Exit: 0 all cases pass; 1 at least one case failed (TDD red); 2 harness
# error (the gate under test is missing, mktemp failed, ...).
#
# Host rules: everything this script writes lives under a mktemp sandbox; it
# never deletes or modifies anything in the repository itself.
set -u

# Root cause of the probe.txt / commit-author leak (issue mojito-async/
# mojito-async#169), found by reproducing it directly: when this script
# runs as a descendant of a REAL git hook, git has already exported
# GIT_DIR and GIT_INDEX_FILE (and, in a linked worktree, GIT_DIR points at
# this worktree's own gitdir under the main checkout's
# .git/worktrees/<name>/) into the hook's environment. `git -C <dir>`
# changes cwd-based repo DISCOVERY only — it does not clear these
# variables, and they win over `-C` for anything that resolves against the
# index or config (`git add`, `git config --local`, ...) even though
# `git -C <dir> rev-parse --show-toplevel` correctly reports <dir> as a
# distinct worktree. That mismatch is exactly why the earlier
# "sb_toplevel != real_toplevel" guard in make_sandbox did not catch it:
# toplevel resolution and index/config resolution follow different rules
# under these variables. Verified live: with GIT_DIR/GIT_INDEX_FILE set to
# this repo's real values, `git -C "$sb" add "$sb/probe.txt"` staged
# probe.txt into the REAL repo's index while `git -C "$sb" rev-parse
# --show-toplevel` still correctly printed "$sb". Unsetting these once,
# here, before any sandbox exists, removes the ambiguity for every git
# command this script (or anything it execs, including the sandboxed
# precommit/gate.sh that run_gate invokes) runs from this point on.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GATE="$SCRIPT_DIR/gate.sh"
REAL_KNOWN_RED="$SCRIPT_DIR/known-red.tsv"

[ -x "$GATE" ] || { echo "test-gate.sh: $GATE missing or not executable"; exit 2; }

TAB=$(printf '\t')
failures=0
cases=0

pass_case() { cases=$((cases + 1)); printf '  %-34s PASS\n' "$1"; }
fail_case() {
    cases=$((cases + 1))
    failures=$((failures + 1))
    printf '  %-34s RED   %s\n' "$1" "$2"
}

# ---------------------------------------------------------------------------
# sandbox: a throwaway git repo carrying a copy of the gate under test
# ---------------------------------------------------------------------------
# $1 = known-red.tsv body, $2 = run-suite.sh body.  Echoes the sandbox path.
#
# The sandbox includes a deterministic `gh` stub so:
#   - issue checks work in sandboxes without real network access
#   - results do not depend on whether a real GitHub issue is open or closed
#     (removing the time-bomb where a test fails the moment an issue closes)
#   - case 4 (closed-issue-row-refused) is correctly tested: the stub returns
#     CLOSED for issue/67 and OPEN for everything else, so the closed-issue
#     detection path in gate.sh is genuinely exercised, not bypassed by the
#     blocked-names check.
make_sandbox() {
    kr=$1
    suite_body=$2
    sb=$(mktemp -d 2>/dev/null) || return 1
    # Every filesystem/git operation below is anchored to $sb explicitly
    # (an absolute path, and `git -C`, never a bare `cd`) rather than
    # relying on a subshell's cwd. A bare `cd "$sb"` inside `( ... )` is
    # supposed to be isolated to that subshell, and `mktemp -d` failing is
    # supposed to make `[ -z "$sb" ]` catch it downstream — but this
    # sandbox WAS observed leaking into the real repo's shared git config
    # (issue mojito-async/mojito-async#169: multiple commits across this
    # session, in both mojito-async and mojito-sys, ended up authored as
    # "gate selftest <gate-selftest@example.invalid>"). `git -C` removes
    # the dependency on `cd` succeeding and on subshell cwd propagation
    # entirely, so whatever the exact mechanism was, it can't recur here.
    [ -n "$sb" ] && [ -d "$sb" ] || return 1
    mkdir -p "$sb/precommit" "$sb/bin" || return 1
    cp "$GATE" "$sb/precommit/gate.sh" || return 1
    chmod +x "$sb/precommit/gate.sh"
    printf '%s\n' "$kr" > "$sb/precommit/known-red.tsv"
    printf '%s\n' "$suite_body" > "$sb/precommit/run-suite.sh"
    chmod +x "$sb/precommit/run-suite.sh"
    # Deterministic gh stub: CLOSED for issue/67 (mojito-sys#67, the real
    # closed issue whose stale row this port removed); OPEN for everything
    # else. No network call, no time-bomb.
    cat > "$sb/bin/gh" <<'GH_STUB'
#!/bin/sh
# Stub for gh api repos/OWNER/REPO/issues/NUM --jq .state
# Returns 'closed' for issue #67 (closed test issue), 'open' otherwise.
# Matches what `gh api ... --jq .state` actually outputs (lowercase string).
for a in "$@"; do
    case "$a" in */67) echo closed; exit 0 ;; esac
done
echo open
GH_STUB
    chmod +x "$sb/bin/gh"
    git -C "$sb" init -q . || return 1
    # Defense-in-depth, now that the actual root cause (ambient
    # GIT_DIR/GIT_INDEX_FILE inherited from a real hook invocation — see
    # the `unset` block at the top of this file) is fixed: verify the
    # sandbox git considers ITSELF ($sb) really is its own repo, distinct
    # from the real one this script lives in, before touching anything
    # with `add` or `config`. This check alone did NOT catch the leak when
    # it was first added, because `git -C "$sb" rev-parse --show-toplevel`
    # still correctly reports $sb even while GIT_INDEX_FILE silently
    # redirects `add`/`config --local` to the real repo underneath it —
    # toplevel and index/config resolution follow different rules under
    # those variables. Kept as a second line of defense: if the `unset`
    # above is ever removed or bypassed, this turns any recurrence into a
    # loud `return 1` here instead of a silent write to the wrong
    # repository.
    sb_toplevel=$(git -C "$sb" rev-parse --show-toplevel 2>/dev/null)
    real_toplevel=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$sb_toplevel" ] || [ "$sb_toplevel" = "$real_toplevel" ]; then
        echo "make_sandbox: sandbox toplevel ('$sb_toplevel') is not a distinct repo from '$real_toplevel'; refusing to proceed" >&2
        return 1
    fi
    git -C "$sb" config --local user.email gate-selftest@example.invalid
    git -C "$sb" config --local user.name  "gate selftest"
    git -C "$sb" config --local commit.gpgsign false
    echo probe > "$sb/probe.txt"
    # Absolute path, not "probe.txt": a bare relative pathspec here is what
    # was observed leaking into the real repo's index under real (hook-
    # driven) invocation, even with `git -C "$sb"` — using $sb/probe.txt
    # removes any ambiguity about which repo's pathspec resolution applies.
    git -C "$sb" add "$sb/probe.txt" || return 1
    added=$(git -C "$sb" diff --cached --name-only)
    if [ "$added" != "probe.txt" ]; then
        echo "make_sandbox: expected only probe.txt staged in sandbox, got: $added" >&2
        return 1
    fi
    printf '%s' "$sb"
}

run_gate() { # $1 = sandbox; sets GATE_OUT / GATE_STATUS
    sb=$1
    if [ -z "$sb" ] || [ ! -d "$sb" ]; then
        GATE_OUT="run_gate: empty or missing sandbox path ('$sb')"
        GATE_STATUS=2
        return
    fi
    GATE_OUT=$(cd "$sb" && PATH="$sb/bin:$PATH" MOJITO_GATE_FAST=0 ./precommit/gate.sh 2>&1)
    GATE_STATUS=$?
}

echo "pre-commit gate self-test (issue mojito-async/mojito-async#169)"
echo ""

# ---------------------------------------------------------------------------
# Case 1 (control): an unlisted driver failure must block the commit.
# This is the one property the gate has always had, and it is here so a
# regression in the OTHER direction — a gate that blocks nothing at all —
# cannot masquerade as a fix.
# ---------------------------------------------------------------------------
sb=$(make_sandbox \
    "# no allow-list rows" \
    "#!/bin/sh
echo 'boom: a driver failed'
exit 1")
if [ -z "$sb" ]; then
    echo "test-gate.sh: sandbox creation failed"; exit 2
fi
run_gate "$sb"
if [ "$GATE_STATUS" -ne 0 ]; then
    pass_case "unlisted-failure-blocks"
else
    fail_case "unlisted-failure-blocks" "gate exited 0 with an unlisted failing check"
fi

# ---------------------------------------------------------------------------
# Case 2: the shipped allow-list must not carry a row named after a
# reserved tier keyword (full/affected/hermetic) — those are never driver
# names run-suite.sh emits, so a row using one would be silently inert at
# best. Battery-level names like `s1-tests`/`bench` ARE legitimate rows in
# this repo (run-suite.sh emits exactly one VERDICT line per battery, never
# one line covering the whole tree — see gate.sh's Tier 1 comment for why
# that's not the same hole `s5-tests` was).
# ---------------------------------------------------------------------------
blanket=$(grep -v '^#' "$REAL_KNOWN_RED" 2>/dev/null \
    | awk -F"$TAB" 'NF>=1 && $1!="" {print $1}' \
    | grep -E '^(full|affected|hermetic)$' || true)
if [ -z "$blanket" ]; then
    pass_case "no-reserved-tier-name-row"
else
    fail_case "no-reserved-tier-name-row" "known-red.tsv allow-lists a reserved tier keyword: $(printf '%s' "$blanket" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Case 3: every allow-list row must carry a name, a tracking issue and the
# date it was added, so a row can be aged out. Two-field rows cannot be.
# ---------------------------------------------------------------------------
malformed=$(grep -v '^#' "$REAL_KNOWN_RED" 2>/dev/null \
    | awk -F"$TAB" '$0!="" { if (NF < 3 || $2 !~ /^https?:\/\// || $3 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) print $1 }' || true)
if [ -z "$malformed" ]; then
    pass_case "rows-carry-issue-and-date"
else
    fail_case "rows-carry-issue-and-date" "row(s) missing issue-url and/or yyyy-mm-dd: $(printf '%s' "$malformed" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Case 4: a row whose tracking issue is CLOSED must be refused by the gate.
# mojito-sys#67 closed 2026-08-27 and its row (`s5-tests`) was still what
# masked the api-mojo lane's real failure; a stale row has to become loud,
# not silent.
# ---------------------------------------------------------------------------
# The row is named s99_closed_probe (not a blocked battery name) so gate.sh
# reaches the closed-issue detection path rather than short-circuiting on the
# name check.  The sandbox gh stub returns CLOSED for issue/67 deterministically.
sb=$(make_sandbox \
    "s99_closed_probe${TAB}https://github.com/mojito-async/mojito-sys/issues/67${TAB}2026-08-30" \
    "#!/bin/sh
printf 'VERDICT\ts99_closed_probe\tRED\n'
echo 'boom: a driver failed'
exit 1")
run_gate "$sb"
if [ "$GATE_STATUS" -ne 0 ]; then
    pass_case "closed-issue-row-refused"
else
    fail_case "closed-issue-row-refused" "gate exited 0 honouring a row that tracks CLOSED issue #67"
fi

# ---------------------------------------------------------------------------
# Case 5: a row older than the staleness horizon must be refused.
# ---------------------------------------------------------------------------
sb=$(make_sandbox \
    "s99_stale_probe${TAB}https://github.com/mojito-async/mojito-sys/issues/173${TAB}2025-01-01" \
    "#!/bin/sh
printf 'VERDICT\ts99_stale_probe\tRED\n'
echo 'boom: a driver failed'
exit 1")
run_gate "$sb"
if [ "$GATE_STATUS" -ne 0 ]; then
    pass_case "stale-row-refused"
else
    fail_case "stale-row-refused" "gate exited 0 honouring a row added 2025-01-01"
fi

# ---------------------------------------------------------------------------
# Case 6: allow-listing is PER DRIVER.  A row for s99_demo must cover
# s99_demo's red and nothing else — a second, unlisted driver failing in the
# same run still has to block the commit.  This is the exact shape that let
# `s5-tests` mask an unrelated real failure elsewhere in S5 if one had ever
# occurred while the row was live.
# ---------------------------------------------------------------------------
sb=$(make_sandbox \
    "s99_demo${TAB}https://github.com/mojito-async/mojito-sys/issues/173${TAB}$(date +%Y-%m-%d)" \
    "#!/bin/sh
printf 'VERDICT\ts99_demo\tRED\n'
printf 'VERDICT\ts98_other\tFAIL\n'
exit 1")
run_gate "$sb"
if [ "$GATE_STATUS" -ne 0 ]; then
    pass_case "per-driver-scope-not-battery-wide"
else
    fail_case "per-driver-scope-not-battery-wide" "gate exited 0 with unlisted driver s98_other failing"
fi

# ---------------------------------------------------------------------------
# Case 7: the converse — a live per-driver row DOES cover its own driver, so
# a genuine TDD red still commits. Without this the fix could be "block
# everything", which is not a working gate either.
# ---------------------------------------------------------------------------
sb=$(make_sandbox \
    "s99_demo${TAB}https://github.com/mojito-async/mojito-sys/issues/173${TAB}$(date +%Y-%m-%d)" \
    "#!/bin/sh
printf 'VERDICT\ts99_demo\tRED\n'
printf 'VERDICT\ts98_other\tPASS\n'
exit 1")
run_gate "$sb"
if [ "$GATE_STATUS" -eq 0 ]; then
    pass_case "live-per-driver-row-honoured"
else
    fail_case "live-per-driver-row-honoured" "gate exited $GATE_STATUS refusing an open, dated, per-driver row"
fi

# ---------------------------------------------------------------------------
# Case 8: a harness/environment failure is never allow-listable. The suite
# runner exiting >= 2 means the suite never ran; a known-red row must not be
# able to turn "I could not measure anything" into a pass.
# ---------------------------------------------------------------------------
sb=$(make_sandbox \
    "s99_demo${TAB}https://github.com/mojito-async/mojito-sys/issues/173${TAB}$(date +%Y-%m-%d)" \
    "#!/bin/sh
echo 'run-suite.sh: dylib cannot be produced'
exit 2")
run_gate "$sb"
if [ "$GATE_STATUS" -ne 0 ]; then
    pass_case "env-failure-not-allow-listable"
else
    fail_case "env-failure-not-allow-listable" "gate exited 0 on a suite runner that never ran (exit 2)"
fi

echo ""
# Per-driver verdict row for precommit/gate.sh: the gate's own test is a
# driver like any other, and is allow-listable by name.
if [ "$failures" -ne 0 ]; then
    printf 'VERDICT\tgate_selftest\tRED\n'
    echo "gate self-test: RED ($failures of $cases case(s) failed)"
    exit 1
fi
printf 'VERDICT\tgate_selftest\tPASS\n'
echo "gate self-test: PASS ($cases cases)"
exit 0
