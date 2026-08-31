# S0/M1.4-T12 -- fresh synthetic-stack context enters and exits cleanly,
# stack reclaimable without corruption (spec 6.5 / S0-T12; issue #12;
# re-pointed for #128).
#
# Drives tests/spike/t12_synth_probe.S (linked directly into this
# executable, statically -- no dlopen/dlsym) against the PRODUCTION
# ms_context_switch/ms_context_init, on a NativeStack.
#
# Scenario: allocate a fresh guarded stack, ms_context_init + switch into a
# context whose entry writes sentinel patterns into a heap scratch block
# and into its own stack region just below SP, then RETURNS through the
# v3 lifecycle's defined completion path (entry returns -> trampoline
# fires the (unregistered, here) finish hook, marks the context FINISHED,
# and tail-switches back to whichever context switched it in last --
# native/posix/ms_context_aarch64.S's `mjs_ctx_trampoline`). The driver
# then verifies every sentinel at identical addresses.
#
# RECLAIM CYCLE, re-derived for NativeStack rather than ms_stack_alloc/
# ms_stack_free: the original S0 probe called the spike's own
# alloc/free pair from a C helper (`t12_reclaim`) to prove a freed stack's
# address range is cleanly reusable. NativeStack owns that same
# alloc/free pair itself (mmap in .create(), munmap in __del__), so this
# leg does the equivalent proof directly in Mojo: explicitly drop the
# first NativeStack via an owned-transfer into a do-nothing function (so
# __del__/munmap runs at an exact, deterministic point rather than
# whenever this toolchain's ASAP destruction happens to fire -- see
# mojito-sys#204), then create a second, same-size NativeStack and prove
# its highest usable byte is genuinely writable.
#
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes for why
# (b2 JIT traps the production v3 lifecycle's first switch).
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204): see t8_gpr_preservation.mojo's
# header note. Same fix applied here, plus the explicit owned-transfer-drop
# described above for the reclaim half.

from native_stack import NativeStack, page_size

@extern("t12_run")
def _t12_run(stack_low: Int, stack_top: Int) abi("C") -> Int: ...


def _drop(var s: NativeStack):
    """Consumes `s` by ownership transfer so its destructor (munmap) runs
    HERE, deterministically, rather than at whatever point this
    toolchain's ASAP destruction would otherwise pick (mojito-sys#204)."""
    pass


def main() raises:
    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)

    var mask = _t12_run(stack.guard_low_address(), stack.top_address())
    _ = stack.base_address()  # keep-alive: see mojito-sys#204

    if mask < 0:
        print("T12 FAIL: probe could not allocate its shared block")
        raise Error("T12 failed: probe allocation")

    if mask & 0xFF != 0:
        print("T12 FAIL: heap scratch corrupted across enter/exit, bitmask:", mask & 0xFF)
        raise Error("T12 failed: heap scratch corrupted")
    if (mask >> 8) & 0xFF != 0:
        print("T12 FAIL: own-stack sentinels corrupted across suspend/resume, bits:", (mask >> 8) & 0xFF)
        raise Error("T12 failed: own-stack sentinels corrupted")
    if mask & (1 << 16) != 0:
        print("T12 FAIL: entry never recorded its own sp")
        raise Error("T12 failed: entry sp not recorded")
    if mask & (1 << 17) != 0:
        print("T12 FAIL: sp not 16-byte aligned at trampoline entry")
        raise Error("T12 failed: trampoline entry misaligned")
    if mask & (1 << 18) != 0:
        print("T12 FAIL: completion marker missing/wrong (completion path not exercised)")
        raise Error("T12 failed: completion marker missing")

    # Reclaim cycle: explicitly free the first stack now (deterministic
    # drop, not ASAP-dependent -- mojito-sys#204), then allocate a fresh
    # same-size stack and prove it is genuinely usable.
    _drop(stack^)

    var stack2 = NativeStack.create(256 * 1024, 256 * 1024, ps)
    var top2 = stack2.top_address()
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=top2 - 1)
    p[] = 42
    var readback = Int(p[])
    _ = stack2.base_address()  # keep-alive: see mojito-sys#204

    if readback != 42:
        print("T12 FAIL: stack free/realloc cycle failed: top-of-stack byte not read back intact")
        raise Error("T12 failed: reclaim readback mismatch")

    print("T12 PASS: synthetic stack entered and exited through completion path; all sentinels intact; equal-size realloc after free succeeded")
