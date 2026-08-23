# S0-T5 — `raises` before yield and cleanup (mojito-sys #11)
#
# Spec §6.5: exercise an error path before a planned yield and confirm ordinary
# cleanup/destruction remains correct.
#
# The alternate context constructs a probe resource and then hits an ordinary
# Mojo error BEFORE ever suspending; unwinding must destroy the resource exactly
# once and no context switch may be recorded.
#
# Red-phase note: imports frozen mojito_spike names; fails until #8/#9/#10 land.

from mojito_spike import ms_ctx_make, ms_ctx_switch, ms_stack_alloc, ms_stack_free

comptime CTX_SLOTS = 22
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
    var self_ctx: UnsafePointer[Byte, MutAnyOrigin]
    var back_ctx: UnsafePointer[Byte, MutAnyOrigin]
    var counters: UnsafePointer[Counters, MutAnyOrigin]
    var error_message: String
    var yields_seen: Int
    var finished: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.counters = UnsafePointer[Counters, MutAnyOrigin](unsafe_from_address=1)
        self.error_message = ""
        self.yields_seen = 0
        self.finished = False


def byte_ptr(p: UnsafePointer[Int, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return p.bitcast[Byte]()


def failing_chain(depth: Int) raises:
    if depth == 0:
        raise Error("pre-yield-failure")
    failing_chain(depth - 1)


def guarded_phase(fp: UnsafePointer[Frame, MutAnyOrigin]) raises:
    # Live resource on the synthetic stack when the error fires.
    var r = Resource(fp[].counters)
    failing_chain(3)
    fp[].yields_seen += 1  # must never run
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)  # must never run


def alt_entry(ud: UnsafePointer[Byte, MutAnyOrigin]):
    var fp = ud.bitcast[Frame]()
    try:
        guarded_phase(fp)
    except e:
        fp[].error_message = String(e)

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

        var cs = Counters()
        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        frame.counters = UnsafePointer[Counters, MutAnyOrigin](to=cs)
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_ctx_make(alt_ctx, top, alt_entry, frame_p)
        # Single entry: ALT errors before yielding and hands straight back.
        ms_ctx_switch(main_ctx, alt_ctx)

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

        ms_stack_free(base)

    print("T5 raises-before-yield cleanup: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T5 failed: " + reason)
