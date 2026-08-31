# spike/stack_switch/ctx_direct.mojo -- M1.4 (#128), switch half.
#
# Mojo bindings for the PRODUCTION context-switch machine edge --
# native/posix/ms_context_aarch64.S's `ms_context_switch`, called through a
# plain `@extern` declaration with NO C function of that name anywhere in
# the loop (ms_context_switch is pure assembly; native/posix/ms_context.c
# only pins its layout with _Static_asserts and never defines a C function
# by that name). This is the harder question spec §15 asks, compared to
# the S0 spike's own spike/context_switch/mojito_spike.mojo, which called
# an analogous but throwaway v2 switch symbol with no per-context lifecycle
# (spike/context_switch/aarch64_switch.S's `ms_ctx_switch`).
#
# WHAT STAYS AND WHAT GOES, relative to the frozen v3 s5-ctx C API
# (native/include/mojito_sys.h):
#   - ms_context_switch: called directly, no adapter. This is THE subject
#     of #128's switch half.
#   - ms_context_init: called directly too, but this is a genuine, small,
#     PRE-EXISTING C function (native/posix/ms_context.c, ~20 lines of
#     stack-geometry validation), not a new shim written for this spike.
#     It is the ONLY publicly documented way to arm a fresh v3 context:
#     the register-level "make" primitive it wraps
#     (`mjs__ctx_make_raw`, in ms_context_aarch64.S) is deliberately
#     `.private_extern`/hidden and is NOT declared in
#     native/include/mojito_sys.h -- reaching around it would mean relying
#     on an undocumented internal layout rather than the frozen ABI. So:
#     the switch itself needed zero adapter; arming a context still goes
#     through the one C entry point the frozen ABI actually promises for
#     that purpose. See the PR body for why this is the honest answer to
#     "how thin can the seam get" rather than a compromise.
#   - ms_context_capture (a ONE-LINE C forwarder,
#     `ms_context_switch(ctx, ctx)`, per ms_context.c) is not used at all:
#     every test below self-captures by calling ms_context_switch(ctx, ctx)
#     directly, since that IS its entire body. This eliminates even that
#     trivial C wrapper from the tests' own call chain.
#   - ms_context_destroy / ms_context_set_finish_hook / ms_context_size /
#     ms_context_alignment are not needed by T1-T14 and are not bound here;
#     T1-T14 only ever exercise create-once-switch-many-times-switch-back.
#
# v3 LIFECYCLE, the one real behavior change from the S0 spike (v2 had no
# per-context state machine at all): every ms_context record now carries a
# state word (DEAD/EMPTY/RUNNING/SUSPENDED/FINISHED) and traps (`brk`, a
# hard SIGTRAP) if `ms_context_switch`'s `to` argument is DEAD, RUNNING, or
# FINISHED. A freshly stack_allocation'd "main" context buffer reads
# whatever garbage was on Mojo's own stack, which is DEAD (0) more often
# than not -- so the FIRST call, `ms_context_switch(main_ctx, alt_ctx)`,
# would eventually try to switch alt BACK into main_ctx (via alt's
# recorded return target) and very likely trap. Every re-pointed test
# below therefore self-captures `main_ctx` via `ms_context_switch(main_ctx,
# main_ctx)` before its first real switch -- the same self-switch
# `ms_context_capture` performs, just called directly (see above). This is
# the one place T1-T14's re-pointed `main()` bodies differ from the
# original S0 versions beyond the import line and stack setup.
#
# AOT, NOT `mojo run`: this migration's OWN prior lane
# (benchmark/ctx/bench_switch.mojo, tests/s5/ctx/api/api_conformance.mojo)
# already measured and documented that the b2 JIT deterministically traps
# on the FIRST ms_context_switch against the production v3 lifecycle
# ("mojo run fails on the first ms_context_switch every time; mojo build +
# run is reliable run-to-run" -- benchmark/ctx/run.sh). Confirmed again
# independently while re-deriving T1-T14 (see PR body). Every re-pointed
# T-test is therefore built with `mojo build` and its compiled binary run
# directly, never `mojo run`; tests/spike/run.sh and run_t8_t14.sh reflect
# this.
#
# Toolchain: Mojo 1.0.0b2 (2cf4d08a).

from std.sys.intrinsics import inlined_assembly

comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]

# sizeof(struct ms_context): frozen v2 168-byte prefix + 32-byte v3
# lifecycle tail (native/include/mojito_sys.h, native/posix/ms_context.c).
comptime MS_CONTEXT_SIZE = 200


# Code address of an @export'd abi("C") Mojo callback, as a raw C function
# pointer -- the S0-spike-proven mechanism (spike/context_switch/
# mojito_spike.mojo's entry_pointer, spike/context_switch/SPIKE_REPORT.md
# item 4: bare Mojo functions cannot convert to pointers on b2, and
# JIT-run exports are dlsym-invisible; adrp/add against the @export'd
# symbol name is the working replacement). `symbol_name` is the @export
# name WITHOUT the Mach-O underscore prefix. Reused verbatim (same
# mechanism, same platform bound: aarch64 Mach-O only).
def entry_pointer[symbol_name: String]() -> BytePtr:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return BytePtr(unsafe_from_address=Int(addr))


@extern("ms_context_init")
def _ms_context_init(
    ctx: BytePtr,
    stack_low: Int,
    stack_size: UInt64,
    entry: BytePtr,
    userdata: Int,
) abi("C") -> Int32: ...


@extern("ms_context_switch")
def ms_context_switch(from_ctx: BytePtr, to_ctx: BytePtr) abi("C"): ...


def _raise_ctx_init_error(rc: Int32) raises:
    # Compiler workaround (b2, issue #29/#30 fold, same discipline as
    # spike/stack_switch/native_stack.mojo's _raise_stack_error): a raising
    # function whose body ALSO lowers an @extern call must keep the raise
    # itself in a SEPARATE, non-inlined function -- an inline
    # `if rc != 0: raise Error(...)` in the SAME body as the
    # ms_context_init extern call crashed this compiler deterministically
    # (3/3 in bisection) until the raise was moved out here.
    raise Error("ms_context_init failed: rc=" + String(rc))


def ms_context_make(
    ctx: BytePtr,
    stack_low: Int,
    stack_top: Int,
    entry: BytePtr,
    userdata: BytePtr,
) raises:
    """Arms `ctx` (MS_CONTEXT_SIZE bytes, caller-owned) so its first resume
    lands on entry(userdata), running on [stack_low, stack_top). Raises on
    any rejection (misaligned span, NULL entry, etc); ctx is left untouched
    by the frozen contract on failure."""
    var stack_size = stack_top - stack_low
    var rc = _ms_context_init(ctx, stack_low, UInt64(stack_size), entry, Int(userdata))
    if rc != 0:
        _raise_ctx_init_error(rc)


def ms_context_capture_self(ctx: BytePtr):
    """Arms `ctx` from the CURRENT execution state -- a later
    ms_context_switch(to=ctx) resumes right after this call. This is
    ms_context_capture's entire body (native/posix/ms_context.c), called
    directly rather than through that one-line C forwarder."""
    ms_context_switch(ctx, ctx)
