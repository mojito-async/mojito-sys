# S0/M1.4-T10 -- stack alignment (spec 6.5 / S0-T10; issue #12; re-pointed
# for #128).
#
# Drives tests/spike/t10_align_probe.S (linked directly into this
# executable, statically -- no dlopen/dlsym) against the PRODUCTION
# ms_context_switch/ms_context_init, on a NativeStack.
#
# Checkpoints covered:
#   * trampoline entry: the probe records the exact hardware SP at
#     trampoline -> entry handoff on the synthetic stack; must be 16-aligned;
#   * post-switch: SP recorded after a yield/resume round trip; must be
#     16-aligned AND identical to the entry SP (non-moving stack);
#   * Mojo function entry: this driver measures frame alignment of freshly
#     entered Mojo functions in the scheduler context, both before and after
#     switching. A 64-byte InlineArray local is used as the probe object so
#     the compiler's preferred alignment applies; it must be 16-byte aligned.
#
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes for why
# (b2 JIT traps the production v3 lifecycle's first switch).
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204): see t8_gpr_preservation.mojo's
# header note. Same fix applied here.

from native_stack import NativeStack, page_size

@extern("t10_run")
def _t10_run(stack_low: Int, stack_top: Int) abi("C") -> Int: ...

@extern("t10_entry_sp")
def _t10_entry_sp() abi("C") -> Int: ...

@extern("t10_resume_sp")
def _t10_resume_sp() abi("C") -> Int: ...


# Alignment observed at the entry of a freshly called Mojo function.
# The 64-byte local array forces the compiler to give the frame its
# preferred (16-byte) alignment if it maintains AAPCS SP discipline.
def _mojo_frame_alignment() -> Int:
    var frame_probe = InlineArray[Int, 8](fill=0)
    return Int(UnsafePointer(to=frame_probe)) & 15


def main() raises:
    # Mojo function entry alignment in the scheduler context, pre-switch.
    var mojo_pre = _mojo_frame_alignment()
    if mojo_pre != 0:
        print("T10 FAIL: freshly entered Mojo frame not 16-byte aligned before switching, misalign:", mojo_pre)
        raise Error("T10 failed: pre-switch Mojo frame misaligned")

    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)
    var top = stack.top_address()

    var mask = _t10_run(stack.guard_low_address(), stack.top_address())
    var entry_sp = _t10_entry_sp()
    var resume_sp = _t10_resume_sp()
    _ = stack.base_address()  # keep-alive: see mojito-sys#204

    if mask < 0:
        print("T10 FAIL: probe could not allocate its shared block")
        raise Error("T10 failed: probe allocation")
    if mask & 1 != 0:
        print("T10 FAIL: sp not 16-byte aligned at trampoline entry")
        raise Error("T10 failed: trampoline entry misaligned")
    if mask & 2 != 0:
        print("T10 FAIL: sp not 16-byte aligned after resume")
        raise Error("T10 failed: post-resume misaligned")
    if mask & 4 != 0:
        print("T10 FAIL: sp changed across yield/resume round trip on non-moving stack")
        raise Error("T10 failed: sp moved across round trip")
    if entry_sp <= top - 256 * 1024 or entry_sp > top:
        print("T10 FAIL: entry sp outside synthetic stack bounds")
        raise Error("T10 failed: entry sp out of bounds")

    # Mojo function entry alignment in the scheduler context, post-switch.
    var mojo_post = _mojo_frame_alignment()
    if mojo_post != 0:
        print("T10 FAIL: freshly entered Mojo frame not 16-byte aligned after switching, misalign:", mojo_post)
        raise Error("T10 failed: post-switch Mojo frame misaligned")

    print("T10 PASS: sp 16-aligned at trampoline entry and post-switch resume; sp stable across round trip; Mojo frames 16-aligned pre/post switch")
