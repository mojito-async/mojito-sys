# NS1 -- NativeStack alloc/free storm, checked against the process mapping
# count (mojito-sys #128, memory half).
#
# Acceptance: "alloc and free storms over thousands of cycles leak no
# mappings, checked against the process mapping count rather than by
# inspection." spike/stack_switch/mapping_probe.c (mach_vm_region_recurse,
# the same primitive `vmmap` itself uses) counts this process's own live VM
# regions; this test samples that count before and after a storm and
# requires the delta to be exactly zero, so a leaking NativeStack.create()/
# __del__ pair is caught by an independent OS-level signal, not by
# re-reading NativeStack's own bookkeeping.
#
# Link: mojo build -I spike/stack_switch -Xlinker <mapping_probe.o> ...
# (this test is AOT-built by tests/spike/run_ns.sh; see that script for the
# exact command and why AOT, not `mojo run`, is used throughout this leg.)

from native_stack import NativeStack, page_size

@extern("msw_count_mappings")
def msw_count_mappings() abi("C") -> Int32: ...

comptime ITERATIONS = 5000
comptime USABLE = 65536


def one_cycle() raises:
    var ps = page_size()
    var s = NativeStack.create(USABLE, ps, ps)
    # Touch the top committed page to prove it is genuinely usable memory,
    # not just a bookkeeping number.
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=s.top_address() - 1)
    p[] = 0x5A
    if p[] != 0x5A:
        raise Error("committed page not writable")
    # s drops at the end of this scope; __del__ releases it exactly once.


def main() raises:
    var ok = True
    var reason = "ok"

    # Warm-up cycle: let any first-use lazy allocation inside Mojo's own
    # runtime (String/Error construction, etc.) happen before the baseline
    # sample, so the storm's own churn isn't blamed on runtime warm-up.
    one_cycle()

    var before = Int(msw_count_mappings())
    var i = 0
    while i < ITERATIONS:
        one_cycle()
        i += 1
    var after = Int(msw_count_mappings())

    if after != before:
        ok = False
        reason = (
            "mapping count drifted: before="
            + String(before)
            + " after="
            + String(after)
            + " delta="
            + String(after - before)
        )

    print(
        "NS1 alloc/free storm ("
        + String(ITERATIONS)
        + " cycles): "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("NS1 failed: " + reason)
