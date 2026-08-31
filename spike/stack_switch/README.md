# M1.4 spike -- Mojo-owned NativeStack + the external `.S` switch (issue #128)

Two halves, run in this order because the second runs on what the first
produces.

## Memory half: `NativeStack`

`native_stack.mojo` is a Mojo-owned, non-moving, guarded native stack built
directly over `mmap`/`mprotect`/`munmap` (`leaf_externs.mojo`) -- no C
substrate anywhere in the loop, unlike `mojito_sys/memory/stack.mojo` (an
earlier, pre-migration wrapper over `native/posix/mjs_stack.c`). Same
layout as `mjs_stack.c`, verified differentially against it
(`tests/spike/ns3_guard_fault_and_c_oracle.mojo`).

Load-bearing finding: this type uses `__del__(deinit self)`, not
`__deinit__(deinit self)`. On the pinned Mojo 1.0.0b2 (2cf4d08a) toolchain,
`__deinit__` -- the spelling this migration's own planning material names
as current, and what `mojito_sys/memory/stack.mojo` /
`mojito_sys/ctx/context.mojo` already use -- is measured to be **silently
never invoked**. Filed as mojito-sys#200 with a minimal reproducer at
`docs/defects/m1-4-deinit-silently-inert.mojo`.

Acceptance tests: `tests/spike/ns1_alloc_free_storm.mojo` through `ns5_*`,
run via `tests/spike/run_ns.sh`. Every test that claims a property was
verified by deliberately mutating the implementation and confirming the
test catches it (see PR body / FINDINGS for the mutation-testing log).

## Switch half: the external `.S` switch

Re-points `tests/spike/t1_*.mojo` through `t14_*` at the PRODUCTION
`native/posix/ms_context_aarch64.S` (`ms_context_switch`, called directly
via a plain `@extern` -- zero C in between) instead of the S0 spike's own
throwaway `spike/context_switch/aarch64_switch.S`. See
`ctx_direct.mojo` and the top-level PR body for the full account of what
needed to change and why (AOT vs JIT, the v3 lifecycle's `capture`
requirement, and so on).

T8-T13 statically link the production `ms_context.o`/`ms_context_aarch64.o`
directly into each Mojo AOT binary alongside a small asm/C probe -- no
`dlopen`/`dlsym`, no throwaway dylib, unlike the S0-era T8-T13 (which
resolved a throwaway spike dylib's symbols at runtime because that
implementation didn't exist yet at the time those tests were TDD-red).
T14 audits a small dedicated dylib built from exactly those same two
production files (see `tests/spike/t14_runtime_audit.sh`), not the
S0-era `libmojito_spike.dylib`.

### Adapter surface

`ctx_direct.mojo` (135 lines) is the ONLY Mojo-side adapter over the
production switch, and it stays that thin because it needs to be: the
switch itself (`ms_context_switch`) is called via a bare `@extern`, zero
lines of adapter beyond the declaration. `ms_context_init` is also called
directly, but it is a genuine pre-existing ~20-line C entry point in
`native/posix/ms_context.c` (the only documented way to arm a v3 context --
the raw register-level "make" primitive is deliberately
`.private_extern`/undocumented), not a shim written for this spike.
`ms_context_capture` (a one-line C forwarder) isn't used at all: every
test self-captures via `ms_context_switch(ctx, ctx)` directly, since
that's its entire body. The only actual "adapter code" in the file is:
`entry_pointer` (the `@export`-symbol-address trick already proven in
the S0 spike, reused verbatim), `ms_context_make` (a raising wrapper
around `ms_context_init`, needed only because Mojo has no other way to
turn a C `-EINVAL`-style return into a `raise`), and the raise-funneling
workaround below. There is no "should this have been a C shim instead"
question left open here: the switch's own seam is already as thin as it
can get.

### Two defects found working this leg (see the PR body for the full account)

- **mojito-sys#204** (Mojo toolchain): a `NativeStack` value is destroyed
  (`__del__`, `munmap`) as soon as its last Mojo-visible use completes --
  even when that "last use" is just deriving two plain `Int` addresses
  that the very next statement dereferences. Every T8-T13 driver carries
  an explicit trailing keep-alive reference to its `NativeStack` (e.g.
  `_ = stack.base_address()`) after the call that consumes those
  addresses, specifically to avoid this. Minimal reproducer:
  `docs/defects/m1-4-native-stack-use-after-free-across-call.mojo`.
- **mojito-sys#205** (build tooling, not Mojo): found via mutation
  testing T9/T12 (deliberately breaking a check and confirming the test
  catches it -- see below) -- `cc`'s integrated assembler treats `;` as
  an end-of-line COMMENT on this target, not a statement separator, so a
  C-preprocessor `#define` macro joining several instructions with `;`
  silently assembles to ONLY its first instruction, with everything after
  discarded and no error or warning anywhere. Compounded by a second,
  independent pitfall: a bare `#param` inside such a macro's body is
  cpp's stringification operator, not an immediate. Together these made
  T9's FP/SIMD comparison and T12's heap/stack sentinel comparisons AND
  writes dead code -- both tests could pass regardless of whether the
  property they claimed to check held. Fixed by converting all six
  affected macros to GNU `.macro`/`.endm` (one instruction per line),
  matching every other macro in these probes, which was never affected.
  Minimal reproducer:
  `docs/defects/m1-4-clang-as-semicolon-comment-and-hash-stringify.S`.

### Mutation testing

Every T8-T13 check was confirmed live by deliberately breaking the
production backend or the probe itself and observing the specific,
correct bit(s) trip -- not just "the test passes on the unmutated code."
This is how mojito-sys#205 above was actually found: T9/T12 kept passing
under mutations that should have failed them, which is what led to
inspecting their disassembly and finding the dead macro expansions. See
the PR body for the specific mutations tried and their exact reported
bitmasks.

### Disassembly evidence

A Mojo-compiled calling frame around `ms_context_switch` (from `t1`'s
`main()`, `otool -tV`) is completely ordinary AAPCS64: a plain `bl`, two
`add`-from-`sp` argument computations, and normal `sp`-relative reads
immediately after return -- no special save/reload sequence around the
call beyond the function's own single prologue (all of x19-x30 pushed
once at entry, per the standard Mojo AOT frame layout). This matches
what the T8/T9 mutation-tested register-preservation checks independently
prove: Mojo relies on (and gets) ordinary AAPCS64 callee-saved discipline
across the switch, nothing more exotic:

```
    add x0, sp, #0x40
    add x1, sp, #0x108
    bl  _ms_context_switch
    ldrb w8, [sp, #0x220]     ; ordinary Mojo code resumes immediately
    tbnz w8, #0x0, 0x100000d58
```

## Re-running

```sh
tests/spike/run_ns.sh            # NativeStack acceptance suite (NS1-NS5)
tests/spike/run.sh                # T1-T7, re-pointed, AOT
tests/spike/run_t8_t14.sh         # T8-T14, re-pointed, AOT, no dylib
```
