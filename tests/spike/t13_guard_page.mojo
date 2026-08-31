# S0/M1.4-T13 -- guard-page overflow faults in a controlled way
# (spec 6.5 / S0-T13; issue #12; re-pointed for #128).
#
# Drives tests/spike/t13_guard_probe.c (linked directly into this
# executable, statically) against a spike/stack_switch/native_stack.mojo
# NativeStack -- no ms_context_* machinery at all here (this test never
# switches contexts), no dlopen/dlsym: NativeStack.create() already
# painted the guard region PROT_NONE, and the driver passes that geometry
# straight to the probe as three plain addresses.
#
# Semantics verified (see t13_guard_probe.c):
#   1. The highest usable byte of a freshly allocated guarded stack is
#      writable in the driver process (no false boundary faults).
#   2. A forked child deliberately writing into the reserved PROT_NONE
#      guard region dies from SIGSEGV/SIGBUS: overflow is an immediate,
#      contained platform fault rather than silent corruption of adjacent
#      memory.
#
# AOT ONLY: see tests/spike/run_t8_t14.sh / the switch-half PR notes --
# this test itself never touches ms_context_switch, but the harness builds
# every T-test the same way (mojo build + run the binary) for uniformity.
#
# KEEP-ALIVE WORKAROUND (mojito-sys#204): see t8_gpr_preservation.mojo's
# header note. Same fix applied here: `stack` is kept alive past the
# @extern call that consumes its derived addresses.

from native_stack import NativeStack, page_size

@extern("t13_run")
def _t13_run(base: Int, guard_low: Int, top: Int) abi("C") -> Int32: ...


def main() raises:
    var ps = page_size()
    var stack = NativeStack.create(256 * 1024, 256 * 1024, ps)

    var code = _t13_run(stack.base_address(), stack.guard_low_address(), stack.top_address())
    _ = stack.base_address()  # keep-alive: see mojito-sys#204

    if code == 0:
        print("T13 PASS: top-of-stack write healthy; overflow into guard page raised a controlled protection fault (SIGBUS/SIGSEGV) in the child - no silent corruption")
        return
    if code == 2:
        print("T13 FAIL: child survived writing into the guard page - guard absent or writable (silent corruption path)")
        raise Error("T13 failed: guard page did not fault")
    if code == 3:
        print("T13 FAIL: child died from an unexpected signal instead of SIGBUS/SIGSEGV")
        raise Error("T13 failed: unexpected child signal")
    if code == 5:
        print("T13 FAIL: waitpid failed while reaping the probe child")
        raise Error("T13 failed: waitpid failed")
    print("T13 FAIL: unknown verdict code:", code)
    raise Error("T13 failed: unknown verdict code " + String(code))
