# mojito pre-commit gate

Every commit in this repo runs `precommit/gate.sh` locally:

- **Tier 0 — validators (always block):** staged whitespace errors, build
  artifacts/junk staged, unresolved conflict markers.
- **Tier 1 — suite (blocks unless known-red):** `precommit/run-suite.sh`,
  scored PER DRIVER against `precommit/known-red.tsv` (issue
  mojito-async/mojito-async#169, ported from mojito-async's gate). Batteries:
  `selftest` (allocator, 31 checks), `t1-t7` (`make test`), `t8-t14`
  (register/TLS/guard/audit), `bench`, `s1-tests`, `s2-tests` and its
  siblings, `s3-atomic-wait` / `s3-other` (S3 split so the atomic_wait
  lane's own known-red row can't shield the rest of S3), `s5-ctx-api` /
  `s5-other` (S5 split so the api lane's own known-red row can't shield
  the rest of S5), `s6-tests`, `no-markers`. A failing driver blocks the
  commit UNLESS it is allow-listed as intentional TDD-red in
  `precommit/known-red.tsv` (with tracking issue); the row must be removed
  when the driver goes green.
- **`MOJITO_GATE_FAST=1`** skips Tier 1 entirely (validators only).

## Cost tiers (issue mojito-async/mojito-async#169)

The gate picks a Tier 1 cost tier from what's actually staged:

| tier | when | what runs |
|---|---|---|
| `hermetic` | every staged path is `*.md` / `docs/**` | `selftest` + `no-markers` only |
| `affected` | every staged path is test-only (`tests/**`, `benchmark/**`, or `precommit/known-red.tsv`) | `selftest` + `no-markers`, plus only the batteries the diff's directories touch |
| `full` | anything else (`native/`, `mojito_sys/`, `Makefile`, the gate itself, a mixed diff, or nothing staged) | every battery, unscoped |

`MOJITO_GATE_TIER=full|affected|hermetic` overrides the auto-pick. CI always
runs `full` explicitly, since a checkout has nothing staged to auto-detect
from. The tier only changes what the local hook checks before a commit
lands — CI's `full` run on the pushed branch is what actually gates the
merge (branch protection on `main` requires it).

## Install

```sh
precommit/install-hooks.sh        # == git config core.hooksPath .githooks
```

The `.githooks/` directory is committed so fresh clones can enable it with
one command. The config itself is per-clone by design (git does not ship
hooks in clones).

## TDD red-test workflow

Lanes land failing tests first (WIP PRs). The gate knows the difference:

1. Branch starts red → add the test name to `precommit/known-red.tsv` in the
   same commit that introduces the failing test, with the tracking issue.
2. Implementation lands → test turns green → remove the row in the same
   commit.
3. Any failure NOT in the allowlist blocks the commit: that is the "don't
   push broken code" contract — the test suite runner is part of the hook.

## Emergency escape hatch

`git commit --no-verify` bypasses the gate. Use it only when the gate itself
is broken (not when tests are red) and file an issue for the gate.

## The `GATE:` trailer

If you use `git commit --no-verify`, add a trailer to the commit message
naming why and what ran instead:

```
GATE: skipped — <reason>. Ran instead: <what you actually verified, e.g.
"./tests/s1/run.sh, PASS">
```

This is not an enforcement mechanism — nothing in git records whether a
hook actually ran, so a trailer is a claim like any commit message, not
proof (mojito-async/mojito-async#169's own finding: two of the four
mojito-sys remediation commits that used `--no-verify` were missing exactly
this trailer). Enforcement lives in CI + branch protection now, not in the
local hook or its trailers. The trailer's job is narrower: it is a
breadcrumb for whoever reads the commit later, so "why was this skipped"
doesn't require asking the author.

## Host rules (same as claude/OX agents on this host)

- This gate never deletes or modifies anything outside the workspace/ tree;
  it builds inside the repo and runs the repo's own suites only.
- Tools that would delete outside workspace/ (e.g. `brew untap`, `git clean`
  of other trees) are NEVER invoked by the gate. If a future gate change
  needs one, it must ask for confirmation first and default to
  `mv <path> <path>.superseded` for retirement.
- `make clean` inside the repo is fine (build artifacts live in `build/`,
  inside the workspace).