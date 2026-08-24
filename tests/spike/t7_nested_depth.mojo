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

from std.memory import stack_allocation

from mojito_spike import (
    BytePtr,
    MS_CTX_SIZE,
    entry_pointer,
    ms_ctx_make,
    ms_ctx_switch,
    ms_stack_alloc,
    ms_stack_free,
)

comptime STACK_BYTES = 262144  # must comfortably hold DEPTH live frames
comptime DEPTH = 64


struct Frame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr
    # Bottom-of-chain -> main signalling for the two planned suspensions.
    var phase: Int  # 1 once the bottom of the chain has been reached
    var unwound: Int  # levels successfully verified during unwind
    var checksum: Int
    var corrupt: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.phase = 0
        self.unwound = 0
        self.checksum = 0
        self.corrupt = False


def expected_checksum() -> Int:
    # Matches unwind order: innermost frame (level 1) contributes first.
    var acc = 0
    var level = 1
    while level <= DEPTH:
        acc = acc * 31 + level * 7
        level += 1
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


@export("t7_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()
    _ = dive(fp, DEPTH)
    # Hand control back one last time; main treats this as completion.
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


def main() raises:
    var ok = True
    var reason = "ok"

    var slots = stack_allocation[2, BytePtr]()
    if ms_stack_alloc(STACK_BYTES, slots, slots + 1) != 0:
        ok = False
        reason = "ms_stack_alloc failed"

    if ok:
        var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var main_ctx = main_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()

        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["t7_alt_entry"](), frame_p)
        ms_ctx_switch(main_ctx, alt_ctx)  # enter; DESCENDS to depth 1 and yields
        if frame.phase != 1:
            ok = False
            reason = (
                "bottom of chain did not signal (phase=" + String(frame.phase) + ")"
            )

        if ok:
            ms_ctx_switch(main_ctx, alt_ctx)  # first planned suspension done
            ms_ctx_switch(main_ctx, alt_ctx)  # unwind completes; entry hands back

            if frame.corrupt:
                ok = False
                reason = "a deep frame's locals were corrupted across suspend/resume"
            if frame.unwound != DEPTH:
                ok = False
                reason = (
                    "only "
                    + String(frame.unwound)
                    + "/"
                    + String(DEPTH)
                    + " frames survived the round trip"
                )
            if frame.checksum != expected_checksum():
                ok = False
                reason = (
                    "checksum mismatch: got "
                    + String(frame.checksum)
                    + ", want "
                    + String(expected_checksum())
                )

        ms_stack_free(slots[])

    print(
        "T7 nested call depth ("
        + String(DEPTH)
        + "): "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("T7 failed: " + reason)
