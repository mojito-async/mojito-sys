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
make test                  # repo root: builds libmojito_spike.dylib, then:
#   tests/spike/run.sh     # PASS/FAIL matrix, nonzero exit on any FAIL
MOJO=/path/to/mojo make test
```

The harness links each test against `libmojito_spike.dylib`
(`mojo run -Xlinker …`) with `-I spike/context_switch`, so tests import the
real frozen `mojito_spike` bindings.

## Status: GREEN

```text
t1_address_stability          PASS
t2_borrowed_refs              PASS
t3_destructor_exactness       PASS
t4_raise_after_resume         PASS
t5_raise_before_yield_cleanup PASS
t6_repeated_switching         PASS
t7_nested_depth               PASS

RESULT: all green (exit 0)
```

Verified against mojo 1.0.0b2 + `libmojito_spike.dylib` from lanes #8/#9/#10;
repeat runs are deterministic.

## Implementation notes

* Entry callbacks follow the #10 mechanism: each test declares its trampoline
  as `@export("tN_alt_entry") def alt_entry(ud: BytePtr) abi("C")` and passes
  `entry_pointer["tN_alt_entry"]()` to `ms_ctx_make`.
* Context save areas are `stack_allocation[MS_CTX_SIZE // 8, Int]()` blocks
  bitcast to `BytePtr`; stack out-slots are `stack_allocation[2, BytePtr]()`.
* Raising helpers (`T4`/`T5`) are plain `raises` defs invoked under
  `try/except` inside the non-raising C-ABI callback, so unwinding happens
  entirely on the synthetic stack.
* Constants use `comptime NAME = ...` (`alias` is deprecated on b2);
  destructors are declared `def __del__(deinit self)`; module-level mutable
  globals don't exist, so all cross-context observations travel through the
  userdata frame pointer.
