# S0 SPIKE REPORT — external-stack execution feasibility (mojito-sys)

Status: FINAL — gate decision below.
Date: 2026-08-23 (matrix rerun on final main 52a00c2)
Toolchain: Mojo 1.0.0b2 (2cf4d08a) via `mojito/brew/mojolang`; macOS arm64 (Apple Silicon), page size 16384.
Repo: github.com/mojito-async/mojito-sys, main tip: 52a00c2 (all six lanes merged).

## Question (spec §6.2)

Can a Mojo function enter through an ordinary Mojo call chain, reach a tiny
C-ABI context-switch shim, transfer control to a separately allocated native
stack on the same OS thread, execute another context, and later resume the
original Mojo frames — without violating observable Mojo semantics and without
relying on private Modular runtime ABI?

## Verdict

**GO** (unconditional for the S0 feasibility question; productionization
constraints listed under Limitations).

- Feasibility: PROVEN. All 14 spec tests green against the real dylib on
  final main; selftest 31/31; benchmark completes clean in isolation
  (83.8M rt/s unloaded; throughput varies with machine load — the
  correctness checks are the gate).


## Evidence

| Suite | Result | Where |
|---|---|---|
| Foundation selftest (allocator) | 31/31 | `make selftest` |
| Sentinel probe (x19–x28 + d8–d15, -O0/-O2) | ALL PRESERVED | `ms_ctx.c` `-DMS_CTX_SENTINEL_PROBE` |
| T1–T7 semantic (address stability, borrows, dtors, raises, 10k switches, depth 64) | 7/7 | `make test` (PR #17) |
| T8–T14 register/TLS/guard/audit | 7/7 | PR #21 (documented per-test build) |
| Bench 1/100/1000 stacks | counter cross-check pass; growth sweep linear; guards referenced to T13 | PR #20 |

Key artifacts:
- `spike/context_switch/aarch64_switch.S` — ms_ctx_make/ms_ctx_switch/trampoline;
  saves x19–x28, fp, lr, **d8–d15** (contract v2, issue #19), sp; 64-entry
  return-to table; loud `brk` traps for misalignment/table-full/re-resume.
- `spike/context_switch/mojito_spike.mojo` — b2-legal bindings +
  **entry-callback mechanism**: `@export` + `abi("C")` callback, address
  materialized by `entry_pointer[symbol]()` (inline asm adrp/add). This was the
  one genuinely hard discovery: bare Mojo functions cannot convert to pointers
  (b2), and JIT-run exports are dlsym-invisible.
- `spike/context_switch/native_stack.c` — mmap allocator, PROT_NONE guard,
  overflow-safe rounding, non-moving reservations.

## Observed Mojo/compiler assumptions (for productionization risk register)

1. `def` only (`fn` removed in b2); `alias` → `comptime`; destructors are
   `def __del__(deinit self)`; no module-level globals.
2. `@extern("sym")` + `def f() abi("C") -> T: ...`; library chosen at link time
   (`-Xlinker`), single-arg decorator.
3. `UnsafePointer` origin params must be concrete in extern signatures
   (MutAnyOrigin for C-raw, MutUntrackedOrigin for stack_allocation scratch).
4. No public fn→pointer cast; nominal function types reject every conversion
   path. Entry mechanism = `@export` + inline-asm adrp/add (works under `mojo
   run` JIT and AOT; dlsym of JIT exports does NOT).
5. `std.sys.intrinsics.inlined_assembly`: JIT crashes with >4 operands and on
   any `ldr` in inline asm (limits in-process syscalls; Mach task_info RSS
   impossible in-process today).
6. `std.time.monotonic()` frozen within a process under JIT;
   `mach_absolute_time` ~40x slow; working clock = `@extern gettimeofday`
   (wall clock — fine for spike benchmarks, revisit for production timers).
7. Compile-time constant folding deletes busy-loops with computable
   accumulators — micro-benchmark bodies must be data-dependent.
8. `mojo run` "unable to locate module" is the intended red for absent modules;
   module resolution needs `-I` for sibling dirs.
9. macOS arm64: PROT_NONE access delivers **SIGBUS** (not SIGSEGV).
10. Int maps to size_t-compatible width on arm64-darwin (64-bit).

## Contract amendments issued during spike

- #16: bindings re-spelled for b2 (C ABI unchanged).
- Trampoline return-to semantics: userdata unmodified; switch records
  to.return_to = caller; trampoline tail-switches there.
- #19 (v2 layout): ms_ctx_t = 168 B (regs[12] @0, fps[8] d8–d15 @96, sp @160)
  after panel proved silent numeric-frame corruption without d8–d15 saves.

## Panel history (5-expert adversarial, per merge)

| PR | Verdict | Fixed in |
|---|---|---|
| #14 foundation | 2 BLOCK → folded (overflow, tautology, unproven usability) | 80f1e79 |
| #15 asm v1 | 3 BLOCK (missing d8–d15 — proven by register poison) | #19 + 9c4d62f |
| #15 asm v2 | 5/5 APPROVE | merged fb44d2b |
| #18 mojo v1 | 1 BLOCK (no entry mechanism) | 3a4ca0b |
| #18 mojo v2 | 5/5 APPROVE | merged b7d1055 |
| #17 tests-a | 5/5 APPROVE | merged 58b9cc2 |
| #21 tests-b | BLOCK (T8/T9 vacuous vs omission; T14 `nm -uU` no-op; T12 skips completion path) | in flight |
| #20 bench | BLOCK (guard metric fabricated; reserved_per misuse; latency 2x mislabel) | in flight |

## Known limitations (accepted for S0, queued for epic #5)

- Single-threaded only (resume-tab and last-from/to globals unsynchronized).
- 64 tracked contexts; table-full traps loudly (no eviction).
- No PAC/BTI (arm64 only; arm64e would need pacibsp/autiasp pairing).
- Apple Mach-O asm only (`#if !__APPLE__ #error`).
- No stack growth; fixed reservations with guard pages.
- Bench: wall-clock timing; histogram clamps >102 µs; RSS via external ps.

## Open items (none blocking the S0 gate)

1. T10's Mojo-frame alignment proxy (local-object address, not hardware SP at
   function entry) — harden in epic #5 if the weak proxy ever matters.
2. Bench JIT fragility under concurrent machine load (crashes inside
   libKGENCompilerRTShared, never inside libmojito_spike) — documented in
   benchmark README; run unloaded or retry.
3. tests/spike/README.md added to the ownership map retroactively (both lanes
   contributed; combined file landed with PR #21).

## Decision

S0 gate: **GO**. The feasibility question is answered YES with three
independent proof layers on final main (52a00c2): compile-time layout pins +
register sentinel probes, 14/14 semantic and register/TLS/guard tests, and a
168M-switch benchmark run with counter cross-check. No private Modular runtime
ABI is referenced (T14 audit, non-vacuous). A0 (mojito-async) is unblocked and
should build against the frozen v2 ABI in CONTRACT.md.
