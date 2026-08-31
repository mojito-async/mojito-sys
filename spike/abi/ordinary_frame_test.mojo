# spike/abi/ordinary_frame_test.mojo — M1.2 (#124) leaf-module-constraint
# probe.
#
# Issue #124's own framing: "the calls have to work from ordinary Mojo
# frames rather than only from a hand-tuned leaf module, because the
# existing externs.mojo files in this repo are pure leaf modules for a
# compiler-defect reason (#49) and a substrate written entirely out of
# leaf modules is not a substrate." This file is the dedicated,
# deliberate VIOLATION of the leaf-module rule: it declares a raw libc
# @extern binding (mmap/munmap) in the SAME module as a Movable struct
# with explicit __moveinit__/__deinit__, a raising function, and a
# control-flow merge before the extern call — the exact shape
# mojito_sys/memory/virtual_memory.mojo and mojito_sys/memory/stack.mojo
# document as the #49/#29/#30 misbind/crash trigger for the mjs_* ABI
# calls this repo already ships. This spike leg asks whether that SAME
# shape misbinds for a RAW libc call too, or whether it is specific to
# the mjs_* calling convention.
#
# RESULT (measured, not assumed): this file compiles, links, and runs
# correctly on macOS arm64 — the mapping is created, its base address is
# nonzero and usable, the destructor's own @extern(munmap) call releases
# it, and the raising branch-merge path (`msg`) does not crash. The
# leaf-module constraint from #49 does NOT reproduce for this raw-libc
# shape on this toolchain, at least for mmap/munmap in this exact
# configuration. This is evidence, not a blanket clearance: #49's own
# reproducer is specific to the mjs_* handle-slot calling convention
# (Int32/pointer-slot arguments crossing through a probe_* shim with
# certain struct/raise interactions); it is not proof that EVERY libc
# call is safe from every non-leaf module shape. Treat this as one
# useful, real data point for #145's audit, not a general theorem.

comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]

@extern("mmap")
def mjo_mmap_ordinary(
    addr: UInt64, length: UInt64, prot: Int32, flags: Int32, fd: Int32,
    offset: Int64,
) abi("C") -> UInt64: ...

@extern("munmap")
def mjo_munmap_ordinary(addr: UInt64, length: UInt64) abi("C") -> Int32: ...


# Movable, explicitly-destroyed struct — mirrors NativeStack/VirtualMemory
# in mojito_sys/memory/*.mojo, which is exactly the shape #49/#29/#30
# document as the trigger: a Movable struct whose __deinit__ lowers an
# @extern call, declared in a module that ALSO declares that @extern.
struct OwnsAMapping(Movable):
    var base: UInt64
    var length: UInt64

    def __init__(out self, base: UInt64, length: UInt64):
        self.base = base
        self.length = length

    def __init__(out self, *, deinit move: Self):
        self.base = move.base
        self.length = move.length

    def __deinit__(deinit self):
        if self.base != 0:
            _ = mjo_munmap_ordinary(self.base, self.length)


# Raising function with a CONTROL-FLOW MERGE before the extern call —
# `msg` is assigned in a branch and its value flows into code that lowers
# the @extern call afterward, the same branch-then-extern-call shape the
# #29/#30 comments describe (there specifically about a String literal
# reaching a `raise` payload through a merge; here the merged value flows
# into ordinary code that precedes the call instead, since this probe
# also wants to check whether the raise itself, not just the branch, is
# what matters).
def make_mapping(length: UInt64, want_fail: Bool) raises -> OwnsAMapping:
    var msg: String
    if want_fail:
        msg = "deliberate failure requested"
    else:
        msg = "normal allocation path"
    print("make_mapping: " + msg)
    if want_fail:
        raise Error("make_mapping: " + msg)
    var addr = mjo_mmap_ordinary(0, length, 3, 0x1002, -1, 0)
    if addr == 0:
        raise Error("make_mapping: mmap failed on the " + msg)
    return OwnsAMapping(addr, length)


# #30's OTHER half: "must NOT lower integer division/remainder in that
# same body" (mojito_sys/memory/stack.mojo's own page-rounding comment —
# the sdiv/srem pipeline SIGSEGVs the compiler when it shares a raising,
# extern-lowering frame). This function deliberately DOES lower integer
# division AND an @extern(mmap) call in the same raising body, rounding
# `length` up to a page-like quantum via a genuine division/remainder
# pair (not a bitmask, on purpose) before mapping it.
def make_mapping_with_division(length: UInt64, quantum: UInt64) raises -> OwnsAMapping:
    if quantum == 0:
        raise Error("make_mapping_with_division: quantum must be nonzero")
    var remainder = length % quantum
    var rounded = length
    if remainder != 0:
        rounded = (length / quantum + 1) * quantum
    var addr = mjo_mmap_ordinary(0, rounded, 3, 0x1002, -1, 0)
    if addr == 0:
        raise Error("make_mapping_with_division: mmap failed")
    return OwnsAMapping(addr, rounded)


def check(name: String, cond: Bool, mut failures: Int) -> Bool:
    print(name + " " + ("PASS" if cond else "FAIL"))
    if not cond:
        failures += 1
    return cond


def main() raises:
    var failures = 0

    # Normal path: allocate, touch memory through it, let the destructor
    # release it via the SAME @extern this module declares.
    var m = make_mapping(16384, False)
    _ = check("ordinary-frame mmap produced a nonzero base", m.base != 0, failures)
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(m.base))
    p[0] = 0x77
    _ = check("ordinary-frame mapping is genuinely usable memory", p[0] == 0x77, failures)

    # Move the struct (exercises __moveinit__ in this same non-leaf frame).
    var m2 = m^
    _ = check("move preserves the base address", m2.base != 0 and p[0] == 0x77, failures)

    # Error path: the raising branch-merge shape, caught and checked.
    var raised = False
    try:
        _ = make_mapping(16384, True)
    except e:
        raised = True
    _ = check("raising branch-merge path raises correctly (no crash)", raised, failures)

    # #30's division-in-extern-frame shape: genuine integer division AND
    # an @extern(mmap) call in the same raising body. If this SIGSEGVs
    # the compiler the way the mjs_* case does, the process never
    # reaches the check below at all — the crash itself IS the result,
    # same as #29/#30's own bisection method.
    var m3 = make_mapping_with_division(20000, 16384)
    _ = check(
        "division-in-extern-frame shape does not crash the compiler"
        " (mapped " + String(m3.length) + " bytes, rounded from 20000)",
        m3.base != 0 and m3.length == 32768,
        failures,
    )

    # m2's __deinit__ runs at end of scope, calling mjo_munmap_ordinary —
    # the destructor-calls-extern shape from the same module, exercised
    # implicitly here; nothing further to assert beyond "did not crash",
    # which a clean process exit already demonstrates.

    print("")
    if failures != 0:
        print("RESULT: " + String(failures) + " FAILED")
        raise Error("ordinary_frame_test FAILED (" + String(failures) + " checks)")
    print("RESULT: all green")
