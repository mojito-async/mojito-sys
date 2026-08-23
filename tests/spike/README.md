# S0 spike semantic tests — T1–T7 (tests-a lane, issue #11)

Semantic conformance tests for the `mojito-sys` context-switch spike,
implementing the mandatory tests **S0-T1 … S0-T7** from
`docs/mojito-sys_IMPLEMENTATION_SPEC.md` §6.5. File ownership per
`spike/context_switch/CONTRACT.md`.

## Files

| Test | File | Spec §6.5 semantics |
|---|---|---|
| T1 | `t1_address_stability.mojo` | Stack-local addresses recorded before suspension are identical after every resumption (non-moving stacks), across 8 suspend/resume cycles. |
| T2 | `t2_borrowed_refs.mojo` | Borrowed references to stack-backed values (struct + array) stay valid across a switch, in both directions: ALT→MAIN writes observed by MAIN, MAIN-stack borrows still intact after ALT resumes; ALT's own synthetic-stack local survives too. |
| T3 | `t3_destructor_exactness.mojo` | Probe type with counting destructor: constructed once, not destroyed at yield (sampled by MAIN while ALT is suspended), destroyed exactly once at scope exit — never duplicated by resume. |
| T4 | `t4_raise_after_resume.mojo` | Ordinary Mojo error raised AFTER resumption propagates through a pre-existing call chain (`raiser_bottom` ×5) up to the frame's handler; live resource destroyed exactly once during unwind. |
| T5 | `t5_raise_before_yield_cleanup.mojo` | Error path BEFORE any planned yield: unwinding destroys the probe exactly once, no switch is recorded, error message crosses back intact via shared state. |
| T6 | `t6_repeated_switching.mojo` | 10000 × A→B→A round trips; both sides increment mutable stack-local accumulators and cross-check handshake counters EVERY iteration. |
| T7 | `t7_nested_depth.mojo` | Configurable `DEPTH = 64` recursion suspends twice at the bottom of a deep ordinary call chain, then unwinds verifying every level's live local and an independently computed checksum. |

## Running

```sh
tests/spike/run.sh            # PASS/FAIL matrix, nonzero exit on any FAIL
MOJO=/path/to/mojo tests/spike/run.sh
```

The harness compiles/runs each test with `mojo run -I spike/context_switch`,
so tests import the frozen `mojito_spike` bindings directly.

## Current status: RED (expected)

All seven tests fail today because lanes #8/#9/#10 have not landed:

```text
t1_address_stability          FAIL
t2_borrowed_refs              FAIL
t3_destructor_exactness       FAIL
t4_raise_after_resume         FAIL
t5_raise_before_yield_cleanup FAIL
t6_repeated_switching         FAIL
t7_nested_depth               FAIL
```

This is the intended TDD red state of this PR; it goes green after central
merges and the `wip` label comes off then.

## API notes for lane #10 (mojito_spike.mojo) and reviewers

Tests were written against Mojo **1.0.0b2** and validated to compile and run
against a scratch stub exposing exactly these shapes (stub NOT part of this
repo):

* Pointer types require origins on b2: raw byte pointers appear as
  `UnsafePointer[Byte, MutAnyOrigin]`. The pre-#16 contract spellings
  (`UnsafePointer[Byte]`) do not compile on b2.
* The frozen `ms_ctx_make(ctx, stack_top, entry, userdata)` accepts the entry
  as a plain named Mojo function; b2 has no public function→pointer cast, so
  the b2-legal formulation is expected to take `entry` through a generic
  parameter (e.g. `[Entry: AnyType]`) or an equivalent mechanism owned by #10.
  Tests pass their trampoline as the bare `alt_entry` function value in the
  third positional slot.
* Constants use `comptime NAME = ...` (`alias` is deprecated on b2);
  destructors are declared `def __del__(deinit self)`; module-level mutable
  globals don't exist, so all cross-context observations travel through the
  userdata frame pointer.

If #10 lands a different entry mechanism, only the single `ms_ctx_make(...)`
call line per test needs adjusting.
