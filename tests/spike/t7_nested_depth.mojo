# S0-T7 — nested call depth (mojito-sys #11)
#
# Spec §6.5: suspend below a configurable deep ordinary Mojo call chain and
# verify all frames remain intact.
#
# A DEPTH-deep recursion descends on the synthetic stack, each level holding a
# live local transformed from its level number; the bottom suspends twice.
# After resumption the chain unwinds, re-verifying every level's local and
# accumulating a checksum that MAIN compares against an independently computed
# expectation.
#
# Red-phase note: imports frozen mojito_spike names; fails until #8/#9/#10 land.

from mojito_spike import ms_ctx_make, ms_ctx_switch, ms_stack_alloc, ms_stack_free

comptime CTX_SLOTS = 22
comptime STACK_BYTES = 262144  # must comfortably hold DEPTH live frames
comptime DEPTH = 64


struct Frame:
    var self_ctx: UnsafePointer[Byte, MutAnyOrigin]
    var back_ctx: UnsafePointer[Byte, MutAnyOrigin]
    # Bottom-of-chain -> main signalling for the two planned suspensions.
    var phase: Int  # 0 = descending/at bottom, 1 = first resume done
    var unwound: Int  # levels successfully verified during unwind
    var checksum: Int
    var corrupt: Bool
    var finished: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.phase = 0
        self.unwound = 0
        self.checksum = 0
        self.corrupt = False
        self.finished = False


def byte_ptr(p: UnsafePointer[Int, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return p.bitcast[Byte]()


# Independent expectation, computed without any context switching.
def expected_checksum() -> Int:
    var acc = 0
    var level = DEPTH
    while level > 0:
        acc = acc * 31 + level * 7
        level -= 1
    return acc


def dive(fp: UnsafePointer[Frame, MutAnyOrigin], level: Int) -> Bool:
    # Live per-frame state derived from the level number.
    var cookie: Int = level * 7

    if level > 1:
        if not dive(fp, level - 1):
            return False

    if level == 1:
        # Bottom of a DEPTH-deep chain: suspend twice before unwinding.
        fp[].phase = 1
        ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)
        ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)

    # Unwind path: every frame's local must be exactly what it stored.
    if cookie != level * 7:
        fp[].corrupt = True
        return False
    fp[].unwound += 1
    fp[].checksum = fp[].checksum * 31 + cookie
    return True


def alt_entry(ud: UnsafePointer[Byte, MutAnyOrigin]):
    var fp = ud.bitcast[Frame]()
    _ = dive(fp, DEPTH)
    fp[].finished = True
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


def main() raises:
    var ok = True
    var reason = "ok"

    var base = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
    var top = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
    if ms_stack_alloc(
        STACK_BYTES,
        UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutAnyOrigin](to=base),
        UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutAnyOrigin](to=top),
    ) != 0:
        ok = False
        reason = "ms_stack_alloc failed"

    if ok:
        var main_buf = InlineArray[Int, CTX_SLOTS](fill=0)
        var alt_buf = InlineArray[Int, CTX_SLOTS](fill=0)
        var main_ctx = byte_ptr(UnsafePointer[Int, MutAnyOrigin](to=main_buf[0]))
        var alt_ctx = byte_ptr(UnsafePointer[Int, MutAnyOrigin](to=alt_buf[0]))

        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_ctx_make(alt_ctx, top, alt_entry, frame_p)
        ms_ctx_switch(main_ctx, alt_ctx)  # enter; DESCENDS to depth 1 and yields
        if frame.phase != 1:
            ok = False
            reason = "bottom of chain did not signal (phase=" + String(frame.phase) + ")"
        ms_ctx_switch(main_ctx, alt_ctx)  # first planned suspension done
        while not frame.finished:
            ms_ctx_switch(main_ctx, alt_ctx)

        if ok and frame.corrupt:
            ok = False
            reason = "a deep frame's locals were corrupted across suspend/resume"
        if ok and frame.unwound != DEPTH:
            ok = False
            reason = (
                "only "
                + String(frame.unwound)
                + "/"
                + String(DEPTH)
                + " frames survived the round trip"
            )
        if ok and frame.checksum != expected_checksum():
            ok = False
            reason = (
                "checksum mismatch: got "
                + String(frame.checksum)
                + ", want "
                + String(expected_checksum())
            )

        ms_stack_free(base)

    print(
        "T7 nested call depth ("
        + String(DEPTH)
        + "): "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("T7 failed: " + reason)
