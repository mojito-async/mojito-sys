# S0-T10 — stack alignment (spec 6.5 / S0-T10; issue #12).
#
# Drives tests/spike/t10_align_probe.S (linked into this executable) through
# the frozen C ABI of include/mojito_spike.h and adds Mojo-side checks.
#
# Checkpoints covered:
#   * trampoline entry: the probe records the exact hardware SP at
#     trampoline -> entry handoff on the synthetic stack; must be 16-aligned;
#   * post-switch: SP recorded after a yield/resume round trip; must be
#     16-aligned AND identical to the entry SP (non-moving stack);
#   * Mojo function entry: this driver measures frame alignment of freshly
#     entered Mojo functions in the scheduler context, both before and after
#     switching. A 64-byte InlineArray local is used as the probe object so
#     the compiler's preferred alignment applies; it must be 16-byte aligned,
#     pointer-sized locals must be at least 8-byte aligned.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t10_init")
def _t10_init() abi("C") -> Int32: ...

@extern("t10_alloc")
def _t10_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t10_free")
def _t10_free() abi("C"): ...

@extern("t10_run")
def _t10_run(top: Int) abi("C") -> Int: ...

@extern("t10_entry_sp")
def _t10_entry_sp() abi("C") -> Int: ...

@extern("t10_resume_sp")
def _t10_resume_sp() abi("C") -> Int: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

# Alignment observed at the entry of a freshly called Mojo function.
# The 64-byte local array forces the compiler to give the frame its
# preferred (16-byte) alignment if it maintains AAPCS SP discipline.
def _mojo_frame_alignment() -> Int:
    var frame_probe = InlineArray[Int, 8](fill=0)
    return Int(UnsafePointer(to=frame_probe)) & 15

def main():
    # Mojo function entry alignment in the scheduler context, pre-switch.
    var mojo_pre = _mojo_frame_alignment()
    if mojo_pre != 0:
        print("T10 FAIL: freshly entered Mojo frame not 16-byte aligned before switching, misalign:", mojo_pre)
        _c_exit(1)

    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T10 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t10_init() != 0:
        print("T10 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var top = _t10_alloc(256 * 1024)
    if top == 0:
        print("T10 FAIL: ms_stack_alloc returned no usable stack")
        _c_exit(1)

    var mask = _t10_run(top)

    var entry_sp = _t10_entry_sp()
    var resume_sp = _t10_resume_sp()
    _t10_free()

    if mask < 0:
        print("T10 FAIL: probe could not allocate its shared block")
        _c_exit(1)
    if mask & 1 != 0:
        print("T10 FAIL: sp not 16-byte aligned at trampoline entry")
        _c_exit(1)
    if mask & 2 != 0:
        print("T10 FAIL: sp not 16-byte aligned after resume")
        _c_exit(1)
    if mask & 4 != 0:
        print("T10 FAIL: sp changed across yield/resume round trip on non-moving stack")
        _c_exit(1)
    if entry_sp <= top - 256 * 1024 or entry_sp > top:
        print("T10 FAIL: entry sp outside synthetic stack bounds")
        _c_exit(1)

    # Mojo function entry alignment in the scheduler context, post-switch.
    var mojo_post = _mojo_frame_alignment()
    if mojo_post != 0:
        print("T10 FAIL: freshly entered Mojo frame not 16-byte aligned after switching, misalign:", mojo_post)
        _c_exit(1)

    print("T10 PASS: sp 16-aligned at trampoline entry and post-switch resume; sp stable across round trip; Mojo frames 16-aligned pre/post switch")
