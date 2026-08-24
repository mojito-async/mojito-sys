# mojito pre-commit gate

Every commit in this repo runs `precommit/gate.sh` locally:

- **Tier 0 — validators (always block):** staged whitespace errors, build
  artifacts/junk staged, unresolved conflict markers.
- **Tier 1 — test suite (blocks unless known-red):** `make selftest`
  (allocator, 31 checks), `make test` (T1–T7 semantic harness), T8–T14
  (register/TLS/guard/audit, via `tests/spike/run_t8_t14.sh`), `make bench`.
  A failing test blocks the commit UNLESS it is allow-listed as an
  intentional TDD-red test in `precommit/known-red.tsv` (with tracking issue);
  the row must be removed when the test goes green.
- **`MOJITO_GATE_FAST=1`** skips the slow suite (T8–T14 builds + bench) for
  hot iterations; validators and T1–T7 still run.

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

## Host rules (same as claude/OX agents on this host)

- This gate never deletes or modifies anything outside the workspace/ tree;
  it builds inside the repo and runs the repo's own suites only.
- Tools that would delete outside workspace/ (e.g. `brew untap`, `git clean`
  of other trees) are NEVER invoked by the gate. If a future gate change
  needs one, it must ask for confirmation first and default to
  `mv <path> <path>.superseded` for retirement.
- `make clean` inside the repo is fine (build artifacts live in `build/`,
  inside the workspace).