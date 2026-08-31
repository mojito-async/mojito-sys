# S0-T3 — destructor exactness (mojito-sys #11)
#
# Spec §6.5: a probe type whose destructor increments a counter must satisfy:
#   constructed once
#   destroyed once
#   not destroyed at yield
#   not duplicated after resume

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


struct Probe:
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
    # Sampled by MAIN while ALT is suspended (must show dtor == 0 at yield).
    var dtor_at_yield: Int
    var invariant_broken: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.counters = UnsafePointer[Counters, MutAnyOrigin](unsafe_from_address=1)
        self.dtor_at_yield = -1
        self.invariant_broken = False


def probe_phase(fp: UnsafePointer[Frame, MutAnyOrigin]):
    var cs = fp[].counters
    var probe = Probe(cs)

    # Constructed exactly once; nothing destroyed yet.
    if cs[].ctor != 1 or cs[].dtor != 0:
        fp[].invariant_broken = True
        return

    # Suspend with probe live. Main samples dtor_at_yield while we are out.
    ms_context_switch(fp[].self_ctx, fp[].back_ctx)

    # Resumed: destructor must NOT have run while suspended, and must not
    # have been duplicated by the resume machinery.
    fp[].dtor_at_yield = cs[].dtor
    # Scope exit of probe_phase destroys `probe` exactly once.


@export("t3_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()
    probe_phase(fp)
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
            entry_pointer["t3_alt_entry"](), frame_p,
        )
        ms_context_switch(main_ctx, alt_ctx)

        # We are back while `probe` is still live on the synthetic stack.
        if cs.ctor != 1 or cs.dtor != 0 or frame.invariant_broken:
            ok = False
            reason = (
                "at yield expected ctor=1/dtor=0, got ctor="
                + String(cs.ctor)
                + "/dtor="
                + String(cs.dtor)
            )

        if ok:
            ms_context_switch(main_ctx, alt_ctx)  # resume; probe scope then exits

            if frame.dtor_at_yield != 0:
                ok = False
                reason = (
                    "destructor ran during suspension (dtor_at_yield="
                    + String(frame.dtor_at_yield)
                    + ")"
                )
            if cs.ctor != 1 or cs.dtor != 1:
                ok = False
                reason = (
                    "final expected ctor=1/dtor=1, got ctor="
                    + String(cs.ctor)
                    + "/dtor="
                    + String(cs.dtor)
                )

        # `stack` drops here (NativeStack.__del__ releases it exactly
        # once); no explicit free call needed.

    print("T3 destructor exactness: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T3 failed: " + reason)
