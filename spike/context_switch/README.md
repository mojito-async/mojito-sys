# S0 Spike — external-stack execution feasibility

Hard go/no-go gate for all stackful work in mojito-sys and for starting
mojito-async. Contract source of truth:
[docs/mojito-sys_IMPLEMENTATION_SPEC.md](../docs/mojito-sys_IMPLEMENTATION_SPEC.md)
Section 6.

## Question

Can ordinary Mojo code safely execute on a mojito-sys-managed, non-moving
native stack, suspend through a stable C-ABI context switch on one OS thread,
and resume with references, destructors, errors, registers, and runtime
assumptions intact?

## Scope

```text
Mojo test harness -> minimal NativeContext -> C-ABI shim -> one arch-specific switch
```

One host OS (macOS arm64), one architecture (aarch64), one thread, two
contexts, guarded non-moving stacks. No scheduler, no reactor, no channels, no
async/await dependency, no `ucontext` as a design dependency.

Constraints: public Mojo facilities only above the C ABI; arch code isolated
below it; live stack addresses stable; explicit reservation + guard page;
platform ABI preserved; no private Modular runtime symbols.

## Semantic tests

| ID    | What it proves                                        |
|-------|-------------------------------------------------------|
| T1    | Stack-local addresses identical before/after suspend  |
| T2    | Borrowed refs to stack values valid after resume      |
| T3    | Destructor runs exactly once, not at yield            |
| T4    | `raises` propagates normally after resume             |
| T5    | Error before yield still cleans up correctly          |
| T6    | High-iteration A->B->A switching, state checked       |
| T7    | Deep call chain intact across suspension              |
| T8    | Callee-saved GPRs preserved                           |
| T9    | Callee-saved FP/SIMD registers preserved              |
| T10   | Alignment at trampoline entry, Mojo entry, post-switch|
| T11   | OS-thread TLS unchanged across switches               |
| T12   | Fresh synthetic-stack context enters/exits cleanly    |
| T13   | Guard page overflow faults in a controlled way        |
| T14   | No private Mojo async/coroutine/runtime symbols used  |

## Benchmarks

A->B->A round trip and derived single-switch cost: switches/sec, median,
p95/p99, cycles where measurable; reserved vs committed bytes; resident memory
for 1/100/1000 stacks. Baseline only — performance is not the go/no-go
criterion unless unremovable overhead defeats project concurrency goals.

## Deliverables & completion

`spike/context_switch/` sources, one arch implementation, minimal C header,
minimal Mojo wrapper, guarded stack allocator, tests T1-T14, benchmarks,
`SPIKE_REPORT.md` (hypothesis, environment, architecture, pass/fail matrix,
performance, compiler assumptions, limitations, GO / CONDITIONAL GO / NO-GO).

S0 is complete only when the repository contains a signed-off SPIKE_REPORT.md
with an explicit decision. Demonstrating a switch is insufficient.
