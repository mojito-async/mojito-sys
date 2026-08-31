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

## Re-running

```sh
tests/spike/run_ns.sh            # NativeStack acceptance suite (NS1-NS5)
tests/spike/run.sh                # T1-T7, re-pointed, AOT
tests/spike/run_t8_t14.sh         # T8-T14, re-pointed
```
