# S0-T1 -- local-address stability (mojito-sys #11, re-pointed for #128)
#
# Spec §6.5: record the addresses of stack locals before suspension and verify
# identical addresses after resumption, across repeated suspend/resume cycles.
#
# RE-POINTED (#128, M1.4): this test now switches through the PRODUCTION
# native/posix/ms_context_aarch64.S `ms_context_switch`, called directly
# via spike/stack_switch/ctx_direct.mojo (zero C wrapper for the switch
# itself), on a spike/stack_switch/native_stack.mojo NativeStack (built
# directly over mmap/mprotect/munmap, no C substrate either) -- not the S0
# spike's own throwaway spike/context_switch/aarch64_switch.S /
# native_stack.c. Built AOT (`mojo build`, not `mojo run`): the b2 JIT
# deterministically traps the production v3 lifecycle's first switch
# (benchmark/ctx/run.sh; confirmed again independently here). `main_ctx`
# is self-captured before the first switch, arming it under the v3
# per-context lifecycle (the S0 v2 backend had no such state machine, so
# the original version never needed this).

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
        ms_context_switch(fp[].self_ctx, fp[].back_ctx)

        if UnsafePointer[Int, MutAnyOrigin](to=marker) != fp[].marker_addr:
            fp[].addr_mismatch = True
        i += 1


def main() raises:
    var ok = True
    var reason = "ok"
    var ps = page_size()

    if ps <= 0:
        ok = False
        reason = "page_size() <= 0"

    var stack = NativeStack()
    if ok:
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
            entry_pointer["t1_alt_entry"](), frame_p,
        )

        # Enter; alternate context yields YIELD_ROUNDS times, then returns.
        ms_context_switch(main_ctx, alt_ctx)
        var rounds = 0
        while rounds < YIELD_ROUNDS and not frame.addr_mismatch:
            ms_context_switch(main_ctx, alt_ctx)
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

        # `stack` drops here (NativeStack.__del__ releases it exactly once);
        # no explicit free call needed.

    print("T1 local-address stability: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T1 failed: " + reason)
