# S0-T13 — guard-page overflow faults in a controlled way
# (spec 6.5 / S0-T13; issue #12).
#
# Drives tests/spike/t13_guard_probe.c (linked into this executable) through
# the frozen C ABI of include/mojito_spike.h.
#
# Semantics verified (see t13_guard_probe.c):
#   1. The highest usable byte of a freshly allocated guarded stack is
#      writable in the driver process (no false boundary faults).
#   2. A forked child deliberately writing into the reserved PROT_NONE guard
#      page dies from SIGSEGV: overflow is an immediate, contained platform
#      fault rather than silent corruption of adjacent memory.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t13_init")
def _t13_init() abi("C") -> Int32: ...

@extern("t13_run")
def _t13_run(num_bytes: Int) abi("C") -> Int32: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T13 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t13_init() != 0:
        print("T13 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var code = _t13_run(256 * 1024)
    if code == 0:
        print("T13 PASS: top-of-stack write healthy; overflow into guard page raised a controlled protection fault (SIGBUS/SIGSEGV) in the child - no silent corruption")
        return
    if code == 2:
        print("T13 FAIL: child survived writing into the guard page - guard absent or writable (silent corruption path)")
        _c_exit(1)
    if code == 3:
        print("T13 FAIL: child died from an unexpected signal instead of SIGBUS/SIGSEGV")
        _c_exit(1)
    if code == 4:
        print("T13 FAIL: ms_stack_alloc failed")
        _c_exit(1)
    if code == 5:
        print("T13 FAIL: waitpid failed while reaping the probe child")
        _c_exit(1)
    print("T13 FAIL: unknown verdict code:", code)
    _c_exit(1)
