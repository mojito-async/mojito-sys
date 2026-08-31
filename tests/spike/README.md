# S0/M1.4 spike semantic tests — T1–T7 (tests-a lane, issue #11; re-pointed
# for #128)

Semantic conformance tests for the `mojito-sys` context-switch spike,
implementing the mandatory tests **S0-T1 … S0-T7** from
`docs/mojito-sys_IMPLEMENTATION_SPEC.md` §6.5. File ownership per
`spike/context_switch/CONTRACT.md`.

Re-pointed (#128, M1.4) at the PRODUCTION `native/posix/ms_context_aarch64.S`
switch, called directly via `spike/stack_switch/ctx_direct.mojo`, on a
`spike/stack_switch/native_stack.mojo` `NativeStack` — see
`spike/stack_switch/README.md` for the full account. T6 now runs
10,000,000 round trips (#128's "ten million repeated switches run clean"
acceptance bar), up from the S0-era 10,000.

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

---

# S0/M1.4 spike semantic tests — T8–T14 (tests-b lane, issue #12; re-pointed
# for #128)

Semantic tests T8–T14 from `docs/mojito-sys_IMPLEMENTATION_SPEC.md` §6.5.
Originally landed as the TDD **red** deliverables against a throwaway S0
spike dylib; RE-POINTED (#128, M1.4) at the PRODUCTION
`native/posix/ms_context_aarch64.S`/`ms_context.c` and a
`spike/stack_switch/native_stack.mojo` `NativeStack` — no dylib, no
`dlopen`/`dlsym`, anywhere in T8-T13 now. All seven run GREEN.

## Design

Each `.mojo` driver is AOT-built (`mojo build`) together with its probe —
an asm/C helper — AND the production `ms_context.o`/`ms_context_aarch64.o`,
all linked statically into the same executable (T13 excepted: it never
switches contexts, so it links only its C probe):

| Test | Driver | Probe | What it proves |
|---|---|---|---|
| T8 | `t8_gpr_preservation.mojo` | `t8_gpr_probe.S` | x19–x28, fp(x29), lr(x30) preserved across `ms_context_switch`; sp 16-aligned at entry/resume |
| T9 | `t9_simd_preservation.mojo` | `t9_simd_probe.S` | d8–d15 (low 64 bits of v8–v15) preserved bit-exactly |
| T10 | `t10_stack_alignment.mojo` | `t10_align_probe.S` | sp 16-aligned at trampoline entry + post-switch resume; sp stable; Mojo frames 16-aligned pre/post switch |
| T11 | `t11_tls_continuity.mojo` | `t11_tls_probe.S` | functional pthread-TSD continuity: seeded TSD magic observed inside B and intact after switch-back; `pthread_self()` unchanged. Raw TPIDR_EL0 reads are captured informationally only (not stable equality targets on macOS arm64). |
| T12 | `t12_synthetic_stack.mojo` | `t12_synth_probe.S` | fresh context enters/exits via the v3 lifecycle's completion path; heap + own-stack sentinels intact; equal-size free/realloc cycle clean (proved directly against `NativeStack.create()`/`__del__`, not a second C entry point) |
| T13 | `t13_guard_page.mojo` | `t13_guard_probe.c` | top-of-stack byte writable; deliberate write into the PROT_NONE guard page raises a controlled protection fault (SIGBUS on macOS arm64, SIGSEGV elsewhere) in a forked child |
| T14 | `t14_runtime_audit.sh` | — | `nm -u`/`nm -gU` audit: no private Mojo/Modular runtime symbols referenced or exported by a dylib built from exactly `ms_context.c` + `ms_context_aarch64.S` |

Every check here was confirmed to be a REAL check, not a vacuous one, by
deliberately mutating the production backend or the probe and observing
the specific expected bit(s) trip in the reported bitmask — see the PR
body for the mutation log. That mutation testing is what surfaced
mojito-sys#205 (a `cc`-integrated-assembler gotcha, not a Mojo defect):
T9's and T12's per-register/per-sentinel comparison macros originally
used `#define`s that silently collapsed to their first instruction on
this assembler, making those specific checks dead code until fixed (now
GNU `.macro`/`.endm`, like every other macro in these probes).

## Building and running

```sh
OUT=tests/spike/.build   # build artifacts live here; safe to rm -rf
mkdir -p "$OUT"
cc -arch arm64 -O2 -I native/include -c native/posix/ms_context.c -o "$OUT/ms_context.o"
cc -arch arm64 -c native/posix/ms_context_aarch64.S -o "$OUT/ms_context_aarch64.o"

# T8
cc -arch arm64 -c tests/spike/t8_gpr_probe.S -o "$OUT/t8_gpr_probe.o"
mojo build -I spike/stack_switch tests/spike/t8_gpr_preservation.mojo -o "$OUT/t8" \
    -Xlinker "$OUT/ms_context.o" -Xlinker "$OUT/ms_context_aarch64.o" -Xlinker "$OUT/t8_gpr_probe.o"
"$OUT/t8"

# T9 / T10 / T11 / T12: identical shape, swap the probe + driver names
cc -arch arm64 -c tests/spike/t9_simd_probe.S -o "$OUT/t9_simd_probe.o"
mojo build -I spike/stack_switch tests/spike/t9_simd_preservation.mojo -o "$OUT/t9" \
    -Xlinker "$OUT/ms_context.o" -Xlinker "$OUT/ms_context_aarch64.o" -Xlinker "$OUT/t9_simd_probe.o"
"$OUT/t9"

# T13 (C helper, no ms_context objects needed -- this test never switches)
cc -arch arm64 -c tests/spike/t13_guard_probe.c -o "$OUT/t13_guard_probe.o"
mojo build -I spike/stack_switch tests/spike/t13_guard_page.mojo -o "$OUT/t13" \
    -Xlinker "$OUT/t13_guard_probe.o"
"$OUT/t13"

# T14 (script; builds and audits its own minimal dylib, no args needed)
tests/spike/t14_runtime_audit.sh
```

Or just run `tests/spike/run_t8_t14.sh`, which does all of the above (plus
the `mojito-sys#202` flaky-compiler-crash retry loop) for every test in
one pass. Exit codes per test binary/script: `0` = PASS, `1` = FAIL
verdict (message says which), T14 additionally uses `2` for "audit dylib
build failed".

## How T13 executes

T13 exercises real memory-protection semantics, so it uses one small C
helper, `t13_guard_probe.c`, linked into the test executable. It takes its
address geometry (`base`, `guard_low`, `top`) directly as three `Int`
arguments from the Mojo driver's `NativeStack` — no `dlopen`, no
`ms_stack_alloc`/`ms_page_size` calls of its own:

1. Parent verifies the single highest usable byte below `top` is writable.
2. It then `fork()`s; the child deliberately stores one byte into the
   middle of the guard region `[base, guard_low)`.
3. The parent reaps the child and requires `WIFSIGNALED` with
   `WTERMSIG == SIGBUS or SIGSEGV` (macOS arm64 delivers SIGBUS for accesses
   to an existing PROT_NONE page). A child that *survives* means the guard
   page was absent or writable — i.e. silent adjacent-memory corruption —
   and fails the test.

The fork isolates the deliberate fault: the driver process itself stays
healthy, which is what "controlled" means here — the platform's page
protection turns overflow into an immediate contained fault.

## How T14 executes

`t14_runtime_audit.sh` builds and audits its own artifact, deliberately
scoped narrower than the full `libmojito_sys.dylib` (which also carries
io_uring/epoll/socket/thread/sync code entirely outside this leg):

1. Builds `libms_context_audit.dylib` from exactly `native/posix/ms_context.c`
   + `native/posix/ms_context_aarch64.S` (nothing else).
2. Screens **undefined** symbols (`nm -u`) and **exported** symbols
   (`nm -gU --defined-only`). System-library imports and the public
   `ms_context_*` ABI are allow-listed; any symbol matching private
   Modular/Mojo runtime patterns
   (`_MLIR/__mlir/modart/asyncRT/kgen/coroutine/__mojo…`) — referenced *or*
   defined — is reported as `FORBIDDEN[...]` and fails the test.
3. Separately confirms `mjs__ctx_make_raw`/`mjs_ctx_trampoline` (deliberately
   `.private_extern` in the `.S`) are NOT among the exported symbols.

## Ownership note

Everything in this directory matching `t[89]_*.mojo` / `t1[0-4]_*.*` belongs
to issue #12 (lane B). The `run.sh` integration target and tests T1–T7 are
owned by tests lane A (issue #11).
