# S0-T3 — destructor exactness (mojito-sys #11)
#
# Spec §6.5: a probe type whose destructor increments a counter must satisfy:
#   constructed once
#   destroyed once
#   not destroyed at yield
#   not duplicated after resume
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


struct Probe:
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
    # Sampled by MAIN while ALT is suspended (must show dtor == 0 at yield).
    var dtor_at_yield: Int
    var finished: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.counters = UnsafePointer[Counters, MutAnyOrigin](unsafe_from_address=1)
        self.dtor_at_yield = -1
        self.finished = False


def byte_ptr(p: UnsafePointer[Int, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return p.bitcast[Byte]()


def probe_phase(fp: UnsafePointer[Frame, MutAnyOrigin]):
    var cs = fp[].counters
    var probe = Probe(cs)

    # Constructed exactly once; nothing destroyed yet.
    if cs[].ctor != 1 or cs[].dtor != 0:
        return

    # Suspend with probe live. Main samples dtor_at_yield while we are out.
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)

    # Resumed: destructor must NOT have run while suspended, and must not
    # have been duplicated by the resume machinery.
    fp[].dtor_at_yield = cs[].dtor
    # Scope exit of probe_phase destroys `probe` exactly once.


def alt_entry(ud: UnsafePointer[Byte, MutAnyOrigin]):
    var fp = ud.bitcast[Frame]()
    probe_phase(fp)

    if fp[].dtor_at_yield < 0:
        # probe_phase bailed early on an invariant violation; surface it so
        # main reports FAIL.
        fp[].dtor_at_yield = -2

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
        ms_ctx_switch(main_ctx, alt_ctx)

        # We are back while `probe` is still alive on the synthetic stack.
        if cs.ctor != 1 or cs.dtor != 0:
            ok = False
            reason = (
                "at yield expected ctor=1/dtor=0, got ctor="
                + String(cs.ctor)
                + "/dtor="
                + String(cs.dtor)
            )

        while not frame.finished:
            ms_ctx_switch(main_ctx, alt_ctx)

        if frame.dtor_at_yield != 0:
            ok = False
            reason = "destructor ran during suspension (dtor_at_yield=" + String(
                frame.dtor_at_yield
            ) + ")"
        if cs.ctor != 1 or cs.dtor != 1:
            ok = False
            reason = (
                "final expected ctor=1/dtor=1, got ctor="
                + String(cs.ctor)
                + "/dtor="
                + String(cs.dtor)
            )

        ms_stack_free(base)

    print("T3 destructor exactness: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T3 failed: " + reason)
