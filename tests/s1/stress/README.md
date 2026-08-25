# tests/s1/stress — S1 stress lane

Guarded-stack memory + stress coverage for issue #31: guarded-stack
geometry, downward growth via the frozen `mjs_vm_commit` service,
non-moving frame invariants, and fork-contained guard/decommit fault
probes.

## Charter

This lane currently owns memory-only coverage. Its charter is
deliberately broader from S2 on: cross-domain stress interleaving stack
growth with context switching, callbacks, and error propagation once
those lanes land (#29/#30/#35). The lane keeps its `tests/s1/stress`
location; this note records the scope so the directory name does not
overpromise today.

## Layout

- `stress_externs.mojo` — single source of truth for every C extern the
  drivers call, plus the MutAnyOrigin out-slot alias (review M3).
- `t_guard_stress.c` — fork probes a Mojo driver cannot express safely:
  guard-page write fault, decommit negative control (MADV_FREE blind
  spot), EINTR-safe reaping.
- `guard_page_test.mojo` — top 16-alignment, highest usable byte
  writable, guard faults loud in child.
- `no_move_test.mojo` — sentinels stable across downward growth;
  first-touch zero-fill; over-commit + decommit negative controls.
- `growth_stress_test.mojo` — 300 downward grow/commit cycles derived
  from live page geometry; first-touch zero-fill every cycle.
- `run.sh` — builds everything into `.build/`, PASS/FAIL matrix;
  exit codes: 0 green, 1 failures, 2 RUN-ERROR.

## TDD red

Until #29/#30 land, drivers fail at link with unresolved-symbol verdicts
(`_mjs_stack_alloc` / `_mjs_vm_commit` / `_mjs_stack_free`). That is the
intended red of issue #31; this PR merges strictly after them (see PR
#39 body).
