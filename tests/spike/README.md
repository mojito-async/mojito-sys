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

---

# S0 spike semantic tests — T8–T14 (tests-b lane, issue #12)

Semantic tests T8–T14 from `docs/mojito-sys_IMPLEMENTATION_SPEC.md` §6.5.
Originally landed as the TDD **red** deliverables (deterministic RED verdicts
while `libmojito_spike.dylib` was absent); all seven now run GREEN against the
merged implementation (main @ b7d1055).

## Design

Each `.mojo` driver is AOT-built (`mojo build`) together with its probe —
an asm/C helper linked statically into the same executable:

| Test | Driver | Probe | What it proves |
|---|---|---|---|
| T8 | `t8_gpr_preservation.mojo` | `t8_gpr_probe.S` | x19–x28, fp(x29), lr(x30) preserved across `ms_ctx_switch`; sp 16-aligned at entry/resume |
| T9 | `t9_simd_preservation.mojo` | `t9_simd_probe.S` | d8–d15 (low 64 bits of v8–v15) preserved bit-exactly |
| T10 | `t10_stack_alignment.mojo` | `t10_align_probe.S` | sp 16-aligned at trampoline entry + post-switch resume; sp stable; Mojo frames 16-aligned pre/post switch |
| T11 | `t11_tls_continuity.mojo` | `t11_tls_probe.S` | functional pthread-TSD continuity: seeded TSD magic observed inside B and intact after switch-back; `pthread_self()` unchanged. Raw TPIDR_EL0 reads are captured informationally only (not stable equality targets on macOS arm64). |
| T12 | `t12_synthetic_stack.mojo` | `t12_synth_probe.S` | fresh context enters/exits via completion path; heap + own-stack sentinels intact; equal-size free/realloc cycle clean |
| T13 | `t13_guard_page.mojo` | `t13_guard_probe.c` | top-of-stack byte writable; deliberate write into the PROT_NONE guard page raises a controlled protection fault (SIGBUS on macOS arm64, SIGSEGV elsewhere) in a forked child |
| T14 | `t14_runtime_audit.sh` | — | `nm -u`/`nm -gU` audit: no private Mojo/Modular runtime symbols referenced or exported by the spike dylib |

Probes contain **no link-time references to the spike**: the drivers
`dlopen("libmojito_spike.dylib")` first, probes resolve `ms_*` symbols with
`dlsym(RTLD_DEFAULT)` afterwards. A missing/incomplete implementation is
therefore a clean `RED` message plus nonzero exit — never a crash or a link
error. When the implementation lands, the same commands turn green without
modification. All probe→spike calls go through the frozen C ABI
(`include/mojito_spike.h`, CONTRACT.md); the Mojo layer proves a Mojo-driven
harness can orchestrate the whole scenario above that boundary.

## Building and running

```sh
OUT=tests/spike/.build   # build artifacts live here; safe to rm -rf
mkdir -p "$OUT"

# T8
clang -arch arm64 -c tests/spike/t8_gpr_probe.S      -o "$OUT/t8_gpr_probe.o"
mojo build tests/spike/t8_gpr_preservation.mojo -o "$OUT/t8" \
    -Xlinker "$OUT/t8_gpr_probe.o"
DYLD_LIBRARY_PATH=<dir-with-libmojito_spike.dylib> "$OUT/t8"

# T9
clang -arch arm64 -c tests/spike/t9_simd_probe.S     -o "$OUT/t9_simd_probe.o"
mojo build tests/spike/t9_simd_preservation.mojo -o "$OUT/t9" \
    -Xlinker "$OUT/t9_simd_probe.o"
DYLD_LIBRARY_PATH=<...> "$OUT/t9"

# T10
clang -arch arm64 -c tests/spike/t10_align_probe.S   -o "$OUT/t10_align_probe.o"
mojo build tests/spike/t10_stack_alignment.mojo -o "$OUT/t10" \
    -Xlinker "$OUT/t10_align_probe.o"
DYLD_LIBRARY_PATH=<...> "$OUT/t10"

# T11
clang -arch arm64 -c tests/spike/t11_tls_probe.S     -o "$OUT/t11_tls_probe.o"
mojo build tests/spike/t11_tls_continuity.mojo -o "$OUT/t11" \
    -Xlinker "$OUT/t11_tls_probe.o"
DYLD_LIBRARY_PATH=<...> "$OUT/t11"

# T12
clang -arch arm64 -c tests/spike/t12_synth_probe.S   -o "$OUT/t12_synth_probe.o"
mojo build tests/spike/t12_synthetic_stack.mojo -o "$OUT/t12" \
    -Xlinker "$OUT/t12_synth_probe.o"
DYLD_LIBRARY_PATH=<...> "$OUT/t12"

# T13 (C helper)
clang -arch arm64 -c tests/spike/t13_guard_probe.c   -o "$OUT/t13_guard_probe.o"
mojo build tests/spike/t13_guard_page.mojo -o "$OUT/t13" \
    -Xlinker "$OUT/t13_guard_probe.o"
DYLD_LIBRARY_PATH=<...> "$OUT/t13"

# T14 (script; needs only the dylib)
tests/spike/t14_runtime_audit.sh
MOJITO_SPIKE_DYLIB=/path/to/libmojito_spike.dylib tests/spike/t14_runtime_audit.sh
```

Exit codes per test binary/script: `0` = PASS, `1` = RED/FAIL verdict
(message says which), T14 additionally uses `2` for "dylib not found".

## How T13 executes

T13 exercises real memory-protection semantics, so it uses one small C
helper, `t13_guard_probe.c`, linked into the test executable:

1. Parent allocates a guarded stack via the spike's `ms_stack_alloc`
   (guard page = `[base, base+page_size)` as `PROT_NONE`) and verifies the
   single highest usable byte below `out_top` is writable.
2. It then `fork()`s; the child deliberately stores one byte into the middle
   of the guard page.
3. The parent reaps the child and requires `WIFSIGNALED` with
   `WTERMSIG == SIGBUS or SIGSEGV` (macOS arm64 delivers SIGBUS for accesses
   to an existing PROT_NONE page). A child that *survives* means the guard
   page was absent or writable — i.e. silent adjacent-memory corruption —
   and fails the test.
4. The stack is freed afterwards.

The fork isolates the deliberate fault: the driver process itself stays
healthy, which is what "controlled" means here — the platform's page
protection turns overflow into an immediate contained fault.

## How T14 executes

`t14_runtime_audit.sh` audits the compiled artifact, no execution of the
switch machinery involved:

1. Locates `libmojito_spike.dylib` (env override `MOJITO_SPIKE_DYLIB`, else
   common repo paths).
2. Screens **undefined** symbols (`nm -uU`) and **exported** symbols
   (`nm -gU --defined-only`). System-library imports (libc/libSystem,
   pthread, mach, malloc/mem*, mmap family, …) and the public `ms_*` ABI are
   allow-listed; any symbol matching private Modular/Mojo runtime patterns
   (`_MLIR/__mlir/modart/asyncRT/kgen/coroutine/__mojo…`) — referenced *or*
   defined — is reported as `FORBIDDEN[...]` and fails the test.
3. Today it exits `2` (RED) because the dylib does not exist yet.

## Ownership note

Everything in this directory matching `t[89]_*.mojo` / `t1[0-4]_*.*` belongs
to issue #12 (lane B). The `run.sh` integration target and tests T1–T7 are
owned by tests lane A (issue #11); once lane A's `make test` harness lands,
these seven tests slot in behind the build commands above.
