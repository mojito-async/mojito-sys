# S0-T9 — callee-saved FP/SIMD register preservation (spec 6.5 / S0-T9; issue #12).
#
# Drives tests/spike/t9_simd_probe.S (linked into this executable) through the
# frozen C ABI of include/mojito_spike.h. AAPCS64 requires callees to preserve
# the low 64 bits of v8-v15 (d8-d15); the probe verifies each bit-exactly
# across a suspend/resume round trip on a guarded synthetic stack.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t9_init")
def _t9_init() abi("C") -> Int32: ...

@extern("t9_alloc")
def _t9_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t9_free")
def _t9_free() abi("C"): ...

@extern("t9_run")
def _t9_run(top: Int) abi("C") -> Int: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T9 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t9_init() != 0:
        print("T9 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var top = _t9_alloc(256 * 1024)
    if top == 0:
        print("T9 FAIL: ms_stack_alloc returned no usable stack")
        _c_exit(1)

    var mask = _t9_run(top)
    _t9_free()

    if mask < 0:
        print("T9 FAIL: probe could not allocate its shared block")
        _c_exit(1)
    if mask != 0:
        print("T9 FAIL: FP/SIMD callee-saved corruption detected, bitmask:", mask)
        _c_exit(1)

    print("T9 PASS: d8-d15 (low 64 bits of v8-v15) preserved bit-exactly across ms_ctx_switch; sp 16-aligned at entry and resume")
