# S0-T6 — repeated switching (mojito-sys #11)
#
# Spec §6.5: perform a high iteration count of
#   context A -> context B -> context A
# with mutable stack-local state checked on EVERY iteration.
#
# 10000 round trips; both sides increment and cross-check handshake counters
# each iteration, plus verify per-side stack-local accumulator invariants.
#
# Red-phase note: imports frozen mojito_spike names; fails until #8/#9/#10 land.

from mojito_spike import ms_ctx_make, ms_ctx_switch, ms_stack_alloc, ms_stack_free

comptime CTX_SLOTS = 22
comptime STACK_BYTES = 262144
comptime ITERATIONS = 10000


struct Frame:
    var self_ctx: UnsafePointer[Byte, MutAnyOrigin]
    var back_ctx: UnsafePointer[Byte, MutAnyOrigin]
    # Handshake state (lives on MAIN's stack, mutated by both sides).
    var rounds_completed: Int
    var mismatch: Bool
    var finished: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.rounds_completed = 0
        self.mismatch = False
        self.finished = False


def byte_ptr(p: UnsafePointer[Int, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return p.bitcast[Byte]()


def alt_entry(ud: UnsafePointer[Byte, MutAnyOrigin]):
    var fp = ud.bitcast[Frame]()

    # Mutable stack-local state on the SYNTHETIC stack, checked every iteration.
    var local_acc: Int = 0

    var i = 1
    while i <= ITERATIONS:
        if fp[].rounds_completed != i - 1:
            fp[].mismatch = True
        local_acc += i
        if local_acc != i * (i + 1) // 2:
            fp[].mismatch = True
        fp[].rounds_completed = i
        ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)
        i += 1

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

        # Mutable MAIN-stack state, checked every iteration.
        var main_acc: Int = 0

        ms_ctx_switch(main_ctx, alt_ctx)  # enter ALT (it completes round 1)
        var i = 1
        while i <= ITERATIONS:
            if frame.rounds_completed != i:
                ok = False
                reason = (
                    "iteration "
                    + String(i)
                    + ": expected rounds="
                    + String(i)
                    + ", saw "
                    + String(frame.rounds_completed)
                )
                break
            main_acc += i
            if main_acc != i * (i + 1) // 2:
                ok = False
                reason = "main accumulator diverged at iteration " + String(i)
                break
            if frame.mismatch:
                ok = False
                reason = "alternate context reported mismatch at iteration " + String(i)
                break
            if i < ITERATIONS:
                ms_ctx_switch(main_ctx, alt_ctx)
            i += 1

        while not frame.finished:
            ms_ctx_switch(main_ctx, alt_ctx)

        if frame.rounds_completed != ITERATIONS:
            ok = False
            reason = "final rounds=" + String(frame.rounds_completed)

        ms_stack_free(base)

    print(
        "T6 repeated switching ("
        + String(ITERATIONS)
        + " iters): "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("T6 failed: " + reason)
