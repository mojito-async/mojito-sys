# S0/M1.4-T6 — repeated switching (mojito-sys #11; re-pointed for #128)
#
# Spec §6.5: perform a high iteration count of
#   context A -> context B -> context A
# with mutable stack-local state checked on EVERY iteration.
#
# 10,000,000 round trips (#128's acceptance bar: "ten million repeated
# switches run clean"); both sides increment and cross-check handshake
# counters each iteration, plus verify per-side stack-local accumulator
# invariants. i*(i+1)/2 at i=10,000,000 is ~5e13, nowhere near Int64
# overflow.

from std.memory import stack_allocation

from native_stack import NativeStack, page_size
from ctx_direct import (
    BytePtr,
    MS_CONTEXT_SIZE,
    entry_pointer,
    ms_context_make,
    ms_context_switch,
    ms_context_capture_self,
)

comptime STACK_BYTES = 262144
comptime ITERATIONS = 10_000_000


struct Frame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr
    # Handshake state (lives on MAIN's stack, mutated by both sides).
    var rounds_completed: Int
    var mismatch: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.rounds_completed = 0
        self.mismatch = False


@export("t6_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
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
        ms_context_switch(fp[].self_ctx, fp[].back_ctx)
        i += 1


def main() raises:
    var ok = True
    var reason = "ok"

    var ps = page_size()
    var stack = NativeStack()
    try:
        stack = NativeStack.create(STACK_BYTES, STACK_BYTES, ps)
    except e:
        ok = False
        reason = "NativeStack.create failed: " + String(e)

    if ok:
        var main_buf = stack_allocation[MS_CONTEXT_SIZE // 8, Int]()
        var alt_buf = stack_allocation[MS_CONTEXT_SIZE // 8, Int]()
        var main_ctx = main_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()
        ms_context_capture_self(main_ctx)

        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_context_make(
            alt_ctx, stack.guard_low_address(), stack.top_address(),
            entry_pointer["t6_alt_entry"](), frame_p,
        )

        # Mutable MAIN-stack state, checked every iteration.
        var main_acc: Int = 0

        ms_context_switch(main_ctx, alt_ctx)  # enter ALT (it completes round 1)
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
                ms_context_switch(main_ctx, alt_ctx)
            i += 1

        if frame.rounds_completed != ITERATIONS:
            ok = False
            reason = "final rounds=" + String(frame.rounds_completed)

        # `stack` drops here (NativeStack.__del__ releases it exactly
        # once); no explicit free call needed.

    print(
        "T6 repeated switching ("
        + String(ITERATIONS)
        + " iters): "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("T6 failed: " + reason)
