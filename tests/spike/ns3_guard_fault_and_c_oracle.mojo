# NS3 -- guard page faults on underflow, matching native/posix/mjs_stack.c's
# behavior (mojito-sys #128, memory half).
#
# Acceptance: "the guard page faults and the fault address matches the C
# implementation." Checked two ways against the SAME oracle function
# (spike/stack_switch/guard_fault_probe.c, mirroring
# tests/spike/t13_guard_probe.c's fork+write+waitpid pattern):
#   1. NativeStack's own mmap'd guard (built directly over mmap/mprotect,
#      no C substrate) faults a forked child that writes into it;
#   2. the REAL C oracle -- native/posix/mjs_stack.c's mjs_stack_alloc,
#      called directly, not reimplemented -- produces the SAME geometry
#      (guard offset from base, reserved size, 16-byte-aligned top) for
#      identical inputs, and faults the SAME way. This is the differential
#      comparison spec §16 asks for: the Mojo-owned implementation is
#      compared against the C implementation it is replacing, not merely
#      asserted correct in isolation.

from std.memory import stack_allocation

from native_stack import NativeStack, page_size

comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]
comptime OutSlots = UnsafePointer[Int, MutAnyOrigin]

@extern("mjs_stack_alloc")
def mjs_stack_alloc(
    reserve_bytes: Int,
    initial_commit_bytes: Int,
    guard_bytes: Int,
    out_base: OutSlots,
    out_guard_low: OutSlots,
    out_top: OutSlots,
) abi("C") -> Int32: ...

@extern("mjs_stack_free")
def mjs_stack_free(base: OutSlots) abi("C") -> Int32: ...

@extern("msw_guard_fault_check")
def msw_guard_fault_check(guard_addr: Int) abi("C") -> Int32: ...


def check(name: String, cond: Bool, mut failures: Int) -> Bool:
    print(name + ": " + ("PASS" if cond else "FAIL"))
    if not cond:
        failures += 1
    return cond


def main() raises:
    var failures = 0
    var ps = page_size()
    comptime USABLE = 65536

    # ---- 1. NativeStack's own guard, built directly over mmap/mprotect ----
    var ns = NativeStack.create(USABLE, ps, ps)
    _ = check("NativeStack top is 16-byte aligned", ns.check_geometry(), failures)

    var top_write = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=ns.top_address() - 1)
    top_write[] = 9
    _ = check("NativeStack top-of-stack byte is writable (no false fault)", top_write[] == 9, failures)

    var ns_guard_addr = ns.base_address() + (ns.guard_bytes // 2)
    var ns_verdict = msw_guard_fault_check(ns_guard_addr)
    _ = check(
        "NativeStack guard page faults a forked child (verdict 0, got " + String(ns_verdict) + ")",
        ns_verdict == 0,
        failures,
    )

    # ---- 2. the C oracle: native/posix/mjs_stack.c, called directly -------
    var c_base = stack_allocation[1, Int]()
    var c_guard_low = stack_allocation[1, Int]()
    var c_top = stack_allocation[1, Int]()
    var rc = mjs_stack_alloc(USABLE, ps, ps, c_base, c_guard_low, c_top)
    _ = check("C oracle mjs_stack_alloc succeeded", rc == 0, failures)

    if rc == 0:
        var c_reserved = c_top[] - c_base[]
        var c_guard_bytes = c_guard_low[] - c_base[]
        var ns_guard_bytes = ns.guard_low_address() - ns.base_address()

        _ = check(
            "reserved size matches the C oracle (Mojo="
            + String(ns.total_reserved())
            + ", C="
            + String(c_reserved)
            + ")",
            ns.total_reserved() == c_reserved,
            failures,
        )
        _ = check(
            "guard size matches the C oracle (Mojo="
            + String(ns_guard_bytes)
            + ", C="
            + String(c_guard_bytes)
            + ")",
            ns_guard_bytes == c_guard_bytes,
            failures,
        )
        _ = check("C oracle top is 16-byte aligned", c_top[] % 16 == 0, failures)

        var c_guard_addr = c_base[] + (c_guard_bytes // 2)
        var c_verdict = msw_guard_fault_check(c_guard_addr)
        _ = check(
            "C oracle guard page faults a forked child the SAME way (verdict 0, got "
            + String(c_verdict)
            + ")",
            c_verdict == 0,
            failures,
        )

        var free_slot = stack_allocation[1, Int]()
        free_slot[] = c_base[]
        _ = mjs_stack_free(free_slot)

    if failures != 0:
        print("RESULT: " + String(failures) + " FAILED")
        raise Error("NS3 failed")
    print("RESULT: all green")
