# S0-T8 — callee-saved GPR preservation (spec 6.5 / S0-T8; issue #12).
#
# Drives tests/spike/t8_gpr_probe.S (linked into this executable) through the
# frozen C ABI of include/mojito_spike.h: ms_stack_alloc, ms_ctx_make,
# ms_ctx_switch, ms_stack_free. The spike dylib is dlopen()ed by name; if it
#
# Verdict: probe returns a corruption bitmask over x19-x28, fp(x29), lr(x30)
# plus sp-alignment checks at trampoline entry and post-switch resume
# (see t8_gpr_probe.S for the bit map). mask == 0 => PASS.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t8_init")
def _t8_init() abi("C") -> Int32: ...

@extern("t8_alloc")
def _t8_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t8_free")
def _t8_free() abi("C"): ...

@extern("t8_run")
def _t8_run(top: Int) abi("C") -> Int: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T8 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t8_init() != 0:
        print("T8 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var top = _t8_alloc(256 * 1024)
    if top == 0:
        print("T8 FAIL: ms_stack_alloc returned no usable stack")
        _c_exit(1)

    var mask = _t8_run(top)
    _t8_free()

    if mask < 0:
        print("T8 FAIL: probe could not allocate its shared block")
        _c_exit(1)
    if mask != 0:
        print("T8 FAIL: callee-saved GPR corruption detected, bitmask:", mask)
        _c_exit(1)

    print("T8 PASS: x19-x28, fp(x29), lr(x30) preserved across ms_ctx_switch; sp 16-aligned at entry and resume")
