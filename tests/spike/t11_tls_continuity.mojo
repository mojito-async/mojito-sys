# S0/M1.4-T11 -- OS-thread TLS continuity across context switches
# (spec 6.5 / S0-T11; issue #12; re-pointed for #128).
#
# Drives tests/spike/t11_tls_probe.S (linked directly into this
# executable, statically -- no dlopen/dlsym) against the PRODUCTION
# ms_context_switch/ms_context_init, on a NativeStack.
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
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes for why
# (b2 JIT traps the production v3 lifecycle's first switch).
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204): see t8_gpr_preservation.mojo's
# header note. Same fix applied here.

from native_stack import NativeStack, page_size

@extern("t11_run")
def _t11_run(stack_low: Int, stack_top: Int) abi("C") -> Int: ...

@extern("t11_tpidr_pre")
def _t11_tpidr_pre() abi("C") -> Int: ...

@extern("t11_tpidr_in")
def _t11_tpidr_in() abi("C") -> Int: ...

@extern("t11_tpidr_post")
def _t11_tpidr_post() abi("C") -> Int: ...


def main() raises:
    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)

    var mask = _t11_run(stack.guard_low_address(), stack.top_address())
    _ = stack.base_address()  # keep-alive: see mojito-sys#204

    if mask < 0:
        print("T11 FAIL: probe could not allocate its shared block")
        raise Error("T11 failed: probe allocation")

    if mask & 1 != 0:
        print("T11 FAIL: TSD value inside synthetic context differs from scheduler's seeded magic")
        raise Error("T11 failed: TSD mismatch inside B")
    if mask & 2 != 0:
        print("T11 FAIL: TSD value after switching back differs from the seeded magic")
        raise Error("T11 failed: TSD mismatch after switch-back")
    if mask & 4 != 0:
        print("T11 FAIL: pthread_self differs inside synthetic context vs pre-switch value")
        raise Error("T11 failed: pthread_self mismatch")
    if mask & 8 != 0:
        print("T11 FAIL: sp not 16-byte aligned at trampoline entry")
        raise Error("T11 failed: trampoline entry misaligned")

    # Informational only (NOT a gate): raw TPIDR_EL0 stability across the run.
    var pre = _t11_tpidr_pre()
    var inb = _t11_tpidr_in()
    var post = _t11_tpidr_post()
    if pre != inb or inb != post:
        print("T11 INFO: TPIDR_EL0 varied across the run (informational; functional TSD continuity is what gates)")

    print("T11 PASS: pthread TSD value continuous across context switches (scheduler seed observed in B, still intact after switch-back); thread identity unchanged; sp 16-aligned at entry")
