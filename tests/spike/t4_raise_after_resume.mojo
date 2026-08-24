# S0-T4 — `raises` after resume (mojito-sys #11)
#
# Spec §6.5: resume a suspended frame and raise an ordinary Mojo error after
# resumption; verify normal propagation through the pre-existing Mojo call
# chain, plus correct cleanup of live values on the resumed stack.

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

comptime STACK_BYTES = 262144
comptime CHAIN_DEPTH = 5


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
    var cleanup_ok: Bool
    var yields_seen: Int

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.counters = UnsafePointer[Counters, MutAnyOrigin](unsafe_from_address=1)
        self.error_message = ""
        self.cleanup_ok = False
        self.yields_seen = 0


# Ordinary Mojo call chain living entirely on the synthetic stack. The raise
# happens only AFTER the frame has been resumed.
def raiser_bottom(depth: Int) raises:
    if depth == 0:
        raise Error("resume-failure-42")
    raiser_bottom(depth - 1)


def guarded_phase(fp: UnsafePointer[Frame, MutAnyOrigin]) raises:
    var r = Resource(fp[].counters)
    # First suspend: nothing is wrong yet.
    fp[].yields_seen += 1
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)

    # Resumed: now raise through the ordinary call chain above this frame.
    raiser_bottom(CHAIN_DEPTH)
    # Unreachable in a correct run; destructor still fires on unwind.
    fp[].cleanup_ok = False


@export("t4_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()
    try:
        guarded_phase(fp)
    except e:
        fp[].error_message = String(e)
        fp[].cleanup_ok = fp[].counters[].ctor == 1 and fp[].counters[].dtor == 1
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

        var cs = Counters()
        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        frame.counters = UnsafePointer[Counters, MutAnyOrigin](to=cs)
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["t4_alt_entry"](), frame_p)
        ms_ctx_switch(main_ctx, alt_ctx)  # enter; ALT yields once

        if cs.dtor != 0 or frame.yields_seen != 1:
            ok = False
            reason = "unexpected state at yield"

        if ok:
            ms_ctx_switch(main_ctx, alt_ctx)  # resume; error raised after resume

            if frame.error_message != "resume-failure-42":
                ok = False
                reason = "error did not propagate intact, got: '" + frame.error_message + "'"
            if not frame.cleanup_ok:
                ok = False
                reason = (
                    "cleanup wrong after unwind: ctor="
                    + String(cs.ctor)
                    + " dtor="
                    + String(cs.dtor)
                )
            if frame.yields_seen != 1:
                ok = False
                reason = "unexpected extra yields"

        ms_stack_free(slots[])

    print("T4 raises-after-resume propagation: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T4 failed: " + reason)
