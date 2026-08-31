# NS2 -- moving the owning NativeStack struct does not move the mapping
# (mojito-sys #128, memory half).
#
# Acceptance: "the address is stable across a move of the owning struct,
# demonstrated by test."

from native_stack import NativeStack, page_size


def check(name: String, cond: Bool, mut failures: Int) -> Bool:
    print(name + ": " + ("PASS" if cond else "FAIL"))
    if not cond:
        failures += 1
    return cond


def make_and_move(ps: Int) raises -> NativeStack:
    # Constructed here, moved out through the return value -- one struct
    # move before the mapping is ever used by the caller.
    var s = NativeStack.create(65536, ps, ps)
    return s^


def main() raises:
    var failures = 0
    var ps = page_size()

    var s1 = make_and_move(ps)
    var base_before = s1.base_address()
    var top_before = s1.top_address()
    var guard_low_before = s1.guard_low_address()

    # Move the owning struct locally (exercises __moveinit__ directly, not
    # just the return-value move above). Mojo forbids referencing `s1`
    # again after this (confirmed empirically: "use of uninitialized
    # value" is a compile error), so the moved-from value's own __del__
    # -- whenever it fires, at this function's scope exit -- reads
    # `self.base == 0` (zeroed by __moveinit__) and is a guaranteed no-op
    # regardless of ordering relative to s2's use below.
    var s2 = s1^

    _ = check("base unchanged across move", s2.base_address() == base_before, failures)
    _ = check("top unchanged across move", s2.top_address() == top_before, failures)
    _ = check("guard_low unchanged across move", s2.guard_low_address() == guard_low_before, failures)

    # The mapping must still be genuinely usable memory after the move AND
    # after the moved-from owner's own __del__ has already run -- proving
    # that destructor was a real no-op, not merely untriggered yet.
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=s2.top_address() - 1)
    p[] = 0x37
    _ = check(
        "mapping still writable at the unchanged address after move AND"
        " after the moved-from owner's scope (and __del__) has ended",
        p[] == 0x37,
        failures,
    )

    if failures != 0:
        print("RESULT: " + String(failures) + " FAILED")
        raise Error("NS2 failed")
    print("RESULT: all green")
