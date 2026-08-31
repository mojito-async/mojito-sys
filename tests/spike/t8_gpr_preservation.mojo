# S0/M1.4-T8 -- callee-saved GPR preservation (spec 6.5 / S0-T8; issue #12;
# re-pointed for #128).
#
# Drives tests/spike/t8_gpr_probe.S (linked directly into this executable,
# statically -- no dlopen/dlsym: the production
# native/posix/ms_context_aarch64.S this probe now drives already exists,
# so there is no "not built yet" case to defer past link time for) against
# the PRODUCTION ms_context_switch/ms_context_init, on a
# spike/stack_switch/native_stack.mojo NativeStack.
#
# Verdict: probe returns a corruption bitmask over x19-x28, fp(x29), lr(x30)
# plus sp-alignment checks at trampoline entry and post-switch resume
# (see t8_gpr_probe.S for the bit map). mask == 0 => PASS.
#
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes for why
# (b2 JIT traps the production v3 lifecycle's first switch).
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204, found while wiring this up): this
# toolchain's ASAP/last-use destructor placement treats `stack`'s last
# Mojo-visible use as the point where its two address accessors are read
# below -- NOT the point where the derived addresses are actually done
# being used by the @extern call that consumes them. Without an explicit
# reference to `stack` AFTER that call, NativeStack.__del__ (munmap) has
# been observed to run BEFORE t8_run's first write into that address
# range, faulting on now-unmapped memory (SIGSEGV, deterministic, not the
# separate #202 compiler-crash pattern). The trailing `stack.base_address()`
# read below is the fix: it moves `stack`'s last use past the call, which
# is all this workaround needs to do.

from native_stack import NativeStack, page_size

@extern("t8_run")
def _t8_run(stack_low: Int, stack_top: Int) abi("C") -> Int: ...


def main() raises:
    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)

    var mask = _t8_run(stack.guard_low_address(), stack.top_address())
    _ = stack.base_address()  # keep-alive: see mojito-sys#204 note above

    if mask < 0:
        print("T8 FAIL: probe could not allocate its shared block")
        raise Error("T8 failed: probe allocation")
    if mask != 0:
        print("T8 FAIL: callee-saved GPR corruption detected, bitmask:", mask)
        raise Error("T8 failed: corruption bitmask " + String(mask))

    print("T8 PASS: x19-x28, fp(x29), lr(x30) preserved across ms_context_switch; sp 16-aligned at entry and resume")
