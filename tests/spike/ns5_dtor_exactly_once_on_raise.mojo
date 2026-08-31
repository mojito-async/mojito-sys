# NS5 -- NativeStack's destructor runs exactly once on the raising path,
# through a multi-frame unwind (mojito-sys #128, memory half).
#
# Acceptance: "the destructor runs exactly once on the raising path."
# Checked two ways: (1) an independent OS-level signal -- the same
# mapping-count oracle NS1 uses -- confirms the mapping is actually gone
# after the unwind, not merely that Mojo THINKS it ran; (2) a live
# NativeStack is held several ordinary Mojo call frames below where the
# raise happens (mirrors tests/spike/t4_raise_after_resume.mojo's
# raiser_bottom chain), so this exercises unwinding through real stack
# frames, not just a single function's own try/except.

from native_stack import NativeStack, page_size

@extern("msw_count_mappings")
def msw_count_mappings() abi("C") -> Int32: ...

comptime CHAIN_DEPTH = 5
comptime USABLE = 65536


def raiser_bottom(depth: Int) raises:
    if depth == 0:
        raise Error("ns5-deliberate-failure")
    raiser_bottom(depth - 1)


def guarded(ps: Int) raises:
    var s = NativeStack.create(USABLE, ps, ps)
    # Touch the stack to prove it is live before the raise unwinds through
    # this frame.
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=s.top_address() - 1)
    p[] = 0x21
    if p[] != 0x21:
        raise Error("setup failed: stack not writable")
    raiser_bottom(CHAIN_DEPTH)
    # Unreachable in a correct run; `s`'s __del__ still fires on unwind.


def main() raises:
    var ok = True
    var reason = "ok"
    var ps = page_size()

    var before = Int(msw_count_mappings())

    var raised = False
    var message = ""
    try:
        guarded(ps)
    except e:
        raised = True
        message = String(e)

    var after = Int(msw_count_mappings())

    if not raised:
        ok = False
        reason = "guarded() did not raise"
    if ok and message != "ns5-deliberate-failure":
        ok = False
        reason = "unexpected error message: '" + message + "'"
    if ok and after != before:
        ok = False
        reason = (
            "mapping leaked across the raising path: before="
            + String(before)
            + " after="
            + String(after)
        )

    # Repeat several times: a destructor that runs ZERO times leaks (caught
    # above); a destructor that runs TWICE double-frees, which on a real
    # mmap region either crashes or, worse, silently unmaps memory the
    # allocator has since reused for something else -- run this several
    # times over so a double-free that only manifests on reused address
    # space gets a chance to surface as a crash rather than passing once
    # by luck.
    #
    # ITERATIONS is deliberately modest (not e.g. 200): a raise propagating
    # through several ordinary Mojo frames while a live NativeStack sits on
    # an ancestor frame, REPEATED many times inside one compiled function,
    # measurably increases the odds of tripping a separate, flaky Mojo
    # 1.0.0b2 compiler crash unrelated to NativeStack's own correctness
    # (filed as mojito-sys#202, with the observed rates at several
    # iteration counts) -- 20 iterations exercises the double-free-under-
    # reuse property with a comfortable safety margin against that crash
    # without needing every CI run to gamble against it.
    comptime ITERATIONS = 20
    var i = 0
    while ok and i < ITERATIONS:
        var before_i = Int(msw_count_mappings())
        var raised_i = False
        try:
            guarded(ps)
        except e:
            raised_i = True
            _ = e
        var after_i = Int(msw_count_mappings())
        if not raised_i or after_i != before_i:
            ok = False
            reason = "repeat " + String(i) + ": raised=" + String(raised_i) + " before=" + String(before_i) + " after=" + String(after_i)
        i += 1

    print("NS5 destructor-exactly-once-on-raise: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("NS5 failed: " + reason)
