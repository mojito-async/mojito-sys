# S0-T1 — local-address stability (mojito-sys #11)
#
# Spec §6.5: record the addresses of stack locals before suspension and verify
# identical addresses after resumption, across repeated suspend/resume cycles.

from std.memory import stack_allocation

from mojito_spike import (
    BytePtr,
    MS_CTX_SIZE,
    entry_pointer,
    ms_ctx_make,
    ms_ctx_switch,
    ms_page_size,
    ms_stack_alloc,
    ms_stack_free,
)

comptime STACK_BYTES = 262144
comptime YIELD_ROUNDS = 8


struct Frame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr
    var marker_addr: UnsafePointer[Int, MutAnyOrigin]
    var resumes_seen: Int
    var addr_mismatch: Bool
    var finished: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.marker_addr = UnsafePointer[Int, MutAnyOrigin](unsafe_from_address=1)
        self.resumes_seen = 0
        self.addr_mismatch = False
        self.finished = False


# Runs on the synthetic stack. The local `marker` must keep its address across
# every suspend/resume: the spike stack is required to be non-moving.
@export("t1_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()

    var marker: Int = 0
    fp[].marker_addr = UnsafePointer[Int, MutAnyOrigin](to=marker)

    var i = 0
    while i < YIELD_ROUNDS:
        fp[].resumes_seen = i
        ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)

        if UnsafePointer[Int, MutAnyOrigin](to=marker) != fp[].marker_addr:
            fp[].addr_mismatch = True
        i += 1


def main() raises:
    var ok = True
    var reason = "ok"

    if ms_page_size() <= 0:
        ok = False
        reason = "ms_page_size() <= 0"

    var slots = stack_allocation[2, BytePtr]()
    var rc = ms_stack_alloc(STACK_BYTES, slots, slots + 1)
    if rc != 0:
        ok = False
        reason = "ms_stack_alloc rc=" + String(rc)

    if ok:
        var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var main_ctx = main_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()

        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["t1_alt_entry"](), frame_p)

        # Enter; alternate context yields YIELD_ROUNDS times, then returns.
        ms_ctx_switch(main_ctx, alt_ctx)
        var rounds = 0
        while rounds < YIELD_ROUNDS and not frame.addr_mismatch:
            ms_ctx_switch(main_ctx, alt_ctx)
            rounds += 1

        if frame.resumes_seen != YIELD_ROUNDS - 1:
            ok = False
            reason = (
                "resumes_seen="
                + String(frame.resumes_seen)
                + ", want "
                + String(YIELD_ROUNDS - 1)
            )
        if frame.addr_mismatch:
            ok = False
            reason = "stack-local address changed across suspend/resume"

        ms_stack_free(slots[])

    print("T1 local-address stability: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T1 failed: " + reason)
