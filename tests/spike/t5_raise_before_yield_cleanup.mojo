# S0-T5 — `raises` before yield and cleanup (mojito-sys #11)
#
# Spec §6.5: exercise an error path before a planned yield and confirm ordinary
# cleanup/destruction remains correct.
#
# The alternate context constructs a probe resource and then hits an ordinary
# Mojo error BEFORE ever suspending; unwinding must destroy the resource exactly
# once and no context switch may be recorded.

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


struct Counters:
    var ctor: Int
    var dtor: Int

    def __init__(out self):
        self.ctor = 0
        self.dtor = 0


struct Resource:
    var counters: UnsafePointer[Counters, MutAnyOrigin]

    def __init__(out self, c: UnsafePointer[Counters, MutAnyOrigin]):
        self.counters = c
        self.counters[].ctor += 1

    def __del__(deinit self):
        self.counters[].dtor += 1


struct Frame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr
    var counters: UnsafePointer[Counters, MutAnyOrigin]
    var error_message: String
    var yields_seen: Int

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.counters = UnsafePointer[Counters, MutAnyOrigin](unsafe_from_address=1)
        self.error_message = ""
        self.yields_seen = 0


def failing_chain(depth: Int) raises:
    if depth == 0:
        raise Error("pre-yield-failure")
    failing_chain(depth - 1)


def guarded_phase(fp: UnsafePointer[Frame, MutAnyOrigin]) raises:
    # Live resource on the synthetic stack when the error fires.
    var r = Resource(fp[].counters)
    failing_chain(3)
    fp[].yields_seen += 1  # must never run
    ms_context_switch(fp[].self_ctx, fp[].back_ctx)  # must never run


@export("t5_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()
    try:
        guarded_phase(fp)
    except e:
        fp[].error_message = String(e)
    # Hand control back one last time; main treats this as completion.
    ms_context_switch(fp[].self_ctx, fp[].back_ctx)


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

        var cs = Counters()
        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        frame.counters = UnsafePointer[Counters, MutAnyOrigin](to=cs)
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_context_make(
            alt_ctx, stack.guard_low_address(), stack.top_address(),
            entry_pointer["t5_alt_entry"](), frame_p,
        )
        # Single entry: ALT errors before yielding and hands straight back.
        ms_context_switch(main_ctx, alt_ctx)

        if frame.error_message != "pre-yield-failure":
            ok = False
            reason = (
                "error message not propagated intact, got: '" + frame.error_message + "'"
            )
        if frame.yields_seen != 0:
            ok = False
            reason = "yield executed despite pre-yield error"
        if cs.ctor != 1 or cs.dtor != 1:
            ok = False
            reason = (
                "cleanup broken on error path: ctor="
                + String(cs.ctor)
                + " dtor="
                + String(cs.dtor)
            )

        # `stack` drops here (NativeStack.__del__ releases it exactly
        # once); no explicit free call needed.

    print("T5 raises-before-yield cleanup: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T5 failed: " + reason)
