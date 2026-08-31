# S0/M1.4-T9 -- callee-saved FP/SIMD register preservation (spec 6.5 /
# S0-T9; issue #12; re-pointed for #128).
#
# Drives tests/spike/t9_simd_probe.S (linked directly into this executable,
# statically -- no dlopen/dlsym) against the PRODUCTION
# ms_context_switch/ms_context_init, on a spike/stack_switch/native_stack.mojo
# NativeStack. AAPCS64 requires callees to preserve the low 64 bits of
# v8-v15 (d8-d15); the probe verifies each bit-exactly across a
# suspend/resume round trip.
#
# Note for #145's gate: issue #194 already found a SIMD/C-struct-layout
# incompatibility elsewhere in this epic (a `SIMD[DType.uint8, N]` struct
# field not matching the equivalent C array layout). That defect is about
# struct FIELD layout; this test is about register save/restore across a
# raw asm context switch, a different mechanism -- there is no SIMD struct
# field anywhere in this probe's shared block (it is plain int64 slots),
# so #194 does not apply here directly. Flagged for the record in case
# something related surfaces.
#
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes for why
# (b2 JIT traps the production v3 lifecycle's first switch).
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204): see t8_gpr_preservation.mojo's
# header note. Same fix applied here.

from native_stack import NativeStack, page_size

@extern("t9_run")
def _t9_run(stack_low: Int, stack_top: Int) abi("C") -> Int: ...


def main() raises:
    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)

    var mask = _t9_run(stack.guard_low_address(), stack.top_address())
    _ = stack.base_address()  # keep-alive: see mojito-sys#204

    if mask < 0:
        print("T9 FAIL: probe could not allocate its shared block")
        raise Error("T9 failed: probe allocation")
    if mask != 0:
        print("T9 FAIL: FP/SIMD callee-saved corruption detected, bitmask:", mask)
        raise Error("T9 failed: corruption bitmask " + String(mask))

    print("T9 PASS: d8-d15 (low 64 bits of v8-v15) preserved bit-exactly across ms_context_switch; sp 16-aligned at entry and resume")
