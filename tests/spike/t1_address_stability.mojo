# S0-T1 — local-address stability (mojito-sys #11)
#
# Spec §6.5: record the addresses of stack locals before suspension and verify
# identical addresses after resumption, across repeated suspend/resume cycles.
#
# Red-phase note: imports the frozen mojito_spike binding names (CONTRACT.md as
# amended by #16). Fails until lanes #8/#9/#10 land.

from mojito_spike import (
    ms_ctx_make,
    ms_ctx_switch,
    ms_page_size,
    ms_stack_alloc,
    ms_stack_free,
)

comptime CTX_SLOTS = 22  # sizeof(ms_ctx_t)/8: 12 callee-saved regs + sp, padded to 176 B
comptime STACK_BYTES = 262144
comptime YIELD_ROUNDS = 8


struct Frame:
    var self_ctx: UnsafePointer[Byte, MutAnyOrigin]
    var back_ctx: UnsafePointer[Byte, MutAnyOrigin]
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


def byte_ptr(p: UnsafePointer[Int, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return p.bitcast[Byte]()


# Runs on the synthetic stack. The local `marker` must keep its address across
# every suspend/resume: the stack is required to be non-moving.
def alt_entry(ud: UnsafePointer[Byte, MutAnyOrigin]):
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

    fp[].resumes_seen = YIELD_ROUNDS
    fp[].finished = True
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


def main() raises:
    var ok = True
    var reason = "ok"

    if ms_page_size() <= 0:
        ok = False
        reason = "ms_page_size() <= 0"

    var base = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
    var top = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
    var rc = ms_stack_alloc(
        STACK_BYTES,
        UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutAnyOrigin](to=base),
        UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutAnyOrigin](to=top),
    )
    if rc != 0:
        ok = False
        reason = "ms_stack_alloc rc=" + String(rc)

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

        ms_ctx_switch(main_ctx, alt_ctx)
        while not frame.finished:
            ms_ctx_switch(main_ctx, alt_ctx)

        if frame.resumes_seen != YIELD_ROUNDS:
            ok = False
            reason = "resumes_seen=" + String(frame.resumes_seen)
        if frame.addr_mismatch:
            ok = False
            reason = "stack-local address changed across suspend/resume"

        ms_stack_free(base)

    print("T1 local-address stability: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T1 failed: " + reason)
