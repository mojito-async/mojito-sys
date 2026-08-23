# S0-T11 — OS-thread TLS continuity across context switches
# (spec 6.5 / S0-T11; issue #12).
#
# Drives tests/spike/t11_tls_probe.S (linked into this executable) through
# the frozen C ABI of include/mojito_spike.h.
#
# A context switch on one OS thread must not disturb thread-local state.
# Verified at three points — before entering the synthetic context, inside
# it, and after resuming the scheduler:
#   * pthread_self() thread identity, captured via libc;
#   * TPIDRROEL0, the userspace-readable TLS base register Apple platforms
#     use for _pthread TSD (read with MRS inside the probe);
# plus a driver-level pthread_self equality check across the whole run.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("pthread_self")
def _c_pthread_self() abi("C") -> Int: ...

@extern("t11_init")
def _t11_init() abi("C") -> Int32: ...

@extern("t11_alloc")
def _t11_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t11_free")
def _t11_free() abi("C"): ...

@extern("t11_run")
def _t11_run(top: Int) abi("C") -> Int: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
    var self_before = _c_pthread_self()

    if _c_dlopen(_addr_of("libmojito_spike.dylib"), 2) == 0:
        print("T11 RED: cannot dlopen libmojito_spike.dylib - spike implementation absent (issues #8/#9)")
        _c_exit(1)
    if _t11_init() != 0:
        print("T11 RED: required spike symbols not resolvable - implementation incomplete")
        _c_exit(1)

    var top = _t11_alloc(256 * 1024)
    if top == 0:
        print("T11 FAIL: ms_stack_alloc returned no usable stack")
        _c_exit(1)

    var mask = _t11_run(top)
    _t11_free()

    if mask < 0:
        print("T11 FAIL: probe could not allocate its shared block")
        _c_exit(1)

    var self_after = _c_pthread_self()
    if self_before != self_after:
        print("T11 FAIL: pthread_self changed across the switching run")
        _c_exit(1)

    if mask & 1 != 0:
        print("T11 FAIL: pthread_self differs inside synthetic context vs pre-switch value")
        _c_exit(1)
    if mask & 2 != 0:
        print("T11 FAIL: TPIDRROEL0 differs inside synthetic context vs pre-switch value")
        _c_exit(1)
    if mask & 4 != 0:
        print("T11 FAIL: pthread_self differs after resume vs inside synthetic context")
        _c_exit(1)
    if mask & 8 != 0:
        print("T11 FAIL: TPIDRROEL0 differs after resume vs inside synthetic context")
        _c_exit(1)
    if mask & 16 != 0:
        print("T11 FAIL: sp not 16-byte aligned at trampoline entry")
        _c_exit(1)

    print("T11 PASS: pthread_self and TPIDRROEL0 identical before, during, and after context switches; sp 16-aligned at entry")
