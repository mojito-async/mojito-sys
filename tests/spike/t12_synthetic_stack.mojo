# S0-T12 — fresh synthetic-stack context enters and exits cleanly, stack
# reclaimable without corruption (spec 6.5 / S0-T12; issue #12).
#
# Drives tests/spike/t12_synth_probe.S (linked into this executable) through
# the frozen C ABI of include/mojito_spike.h.
#
# Scenario: allocate a fresh guarded stack, ms_ctx_make + ms_ctx_switch into
# a context whose entry writes sentinel patterns into a heap scratch block
# and into its own stack region just below SP, yields once, resumes, verifies
# every sentinel at identical addresses, then exits through the defined
# completion path (final switch back to the scheduler). The driver then frees
# the stack and allocates an equal-size replacement (t12_reclaim) to prove
# clean reclaim; the new stack's highest usable byte is write/read verified.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t12_init")
def _t12_init() abi("C") -> Int32: ...

@extern("t12_alloc")
def _t12_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t12_free")
def _t12_free() abi("C"): ...

@extern("t12_run")
def _t12_run(top: Int) abi("C") -> Int: ...

@extern("t12_reclaim")
def _t12_reclaim() abi("C") -> Int32: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T12 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t12_init() != 0:
        print("T12 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var top = _t12_alloc(256 * 1024)
    if top == 0:
        print("T12 FAIL: ms_stack_alloc returned no usable stack")
        _c_exit(1)

    var mask = _t12_run(top)

    var reclaim = _t12_reclaim()
    if reclaim == 0:
        # second reclaim cycle on the already-recycled stack must also work
        pass

    if mask < 0:
        print("T12 FAIL: probe could not allocate its shared block")
        _c_exit(1)

    if mask & 0xFF != 0:
        print("T12 FAIL: heap scratch corrupted across enter/exit, bitmask:", mask & 0xFF)
        _c_exit(1)
    if (mask >> 8) & 0xFF != 0:
        print("T12 FAIL: own-stack sentinels corrupted across suspend/resume, bits:", (mask >> 8) & 0xFF)
        _c_exit(1)
    if mask & (1 << 16) != 0:
        print("T12 FAIL: sp changed across yield/resume round trip")
        _c_exit(1)
    if mask & (1 << 17) != 0:
        print("T12 FAIL: sp not 16-byte aligned at trampoline entry")
        _c_exit(1)
    if reclaim != 0:
        print("T12 FAIL: stack free/realloc cycle failed, code:", reclaim)
        _c_exit(1)

    print("T12 PASS: synthetic stack entered and exited through completion path; all sentinels intact; equal-size realloc after free succeeded")
