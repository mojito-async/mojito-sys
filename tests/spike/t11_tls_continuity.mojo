# S0-T11 — OS-thread TLS continuity across context switches
# (spec 6.5 / S0-T11; issue #12).
#
# Drives tests/spike/t11_tls_probe.S (linked into this executable) through
# the frozen C ABI of include/mojito_spike.h.
#
# The spec invariant ("OS-thread TLS remains unchanged") is verified
# FUNCTIONALLY through the pthread TSD API:
#   * scheduler seeds a TSD key with a magic before entering the synthetic
#     context;
#   * inside the synthetic context, pthread_getspecific(key) must return the
#     seeded magic and pthread_self() must be unchanged;
#   * after switching back, pthread_getspecific(key) must still return the
#     magic;
# plus an INFORMATIONAL (non-gating) TPIDR_EL0 stability report: raw
# TLS-pointer register values are not a reliable equality target on macOS
# arm64 (libSystem may legitimately rewrite TPIDR_EL0; TPIDRRO_EL0 is not
# guaranteed stable read-to-read), so only the functional check gates.
#
# The spike dylib is dlopen()ed by name; if it is absent the test reports a
# deterministic RED verdict and exits nonzero.

@extern("dlopen")
def _c_dlopen(path: Int, mode: Int32) abi("C") -> Int: ...

@extern("exit")
def _c_exit(code: Int32) abi("C"): ...

@extern("t11_init")
def _t11_init() abi("C") -> Int32: ...

@extern("t11_alloc")
def _t11_alloc(num_bytes: Int) abi("C") -> Int: ...

@extern("t11_free")
def _t11_free() abi("C"): ...

@extern("t11_run")
def _t11_run(top: Int) abi("C") -> Int: ...

@extern("t11_tpidr_pre")
def _t11_tpidr_pre() abi("C") -> Int: ...

@extern("t11_tpidr_in")
def _t11_tpidr_in() abi("C") -> Int: ...

@extern("t11_tpidr_post")
def _t11_tpidr_post() abi("C") -> Int: ...

def _addr_of(s: String) -> Int:
    var buf = InlineArray[Byte, 128](fill=Byte(0))
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    return Int(UnsafePointer(to=buf))

def main():
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

    if mask & 1 != 0:
        print("T11 FAIL: TSD value inside synthetic context differs from scheduler's seeded magic")
        _c_exit(1)
    if mask & 2 != 0:
        print("T11 FAIL: TSD value after switching back differs from the seeded magic")
        _c_exit(1)
    if mask & 4 != 0:
        print("T11 FAIL: pthread_self differs inside synthetic context vs pre-switch value")
        _c_exit(1)
    if mask & 8 != 0:
        print("T11 FAIL: sp not 16-byte aligned at trampoline entry")
        _c_exit(1)

    # Informational only (NOT a gate): raw TPIDR_EL0 stability across the run.
    var pre = _t11_tpidr_pre()
    var inb = _t11_tpidr_in()
    var post = _t11_tpidr_post()
    if pre != inb or inb != post:
        print("T11 INFO: TPIDR_EL0 varied across the run (informational; functional TSD continuity is what gates)")

    print("T11 PASS: pthread TSD value continuous across context switches (scheduler seed observed in B, still intact after switch-back); thread identity unchanged; sp 16-aligned at entry")
