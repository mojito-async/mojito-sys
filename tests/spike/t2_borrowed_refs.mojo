# S0-T2 — borrowed-reference validity (mojito-sys #11)
#
# Spec §6.5: hold references to stack-backed Mojo values across the context
# switch and verify they remain usable after resume.
#
# Two directions are checked:
#   * the alternate context borrows pointers to MAIN-stack objects and uses
#     them before and after being resumed;
#   * main re-verifies its own stack-backed objects after every switch back.

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
comptime PATTERN_LEN = 16


struct Payload:
    var tag: Int
    var value: Int

    def __init__(out self, tag: Int, value: Int):
        self.tag = tag
        self.value = value


struct Frame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr
    # Borrows into MAIN's stack frame:
    var borrowed_payload: UnsafePointer[Payload, MutAnyOrigin]
    var borrowed_array: UnsafePointer[Int, MutAnyOrigin]
    # Borrows into ALT's stack frame (main observes the writeback):
    var alt_scratch: UnsafePointer[Int, MutAnyOrigin]
    var corrupt: Bool

    def __init__(out self):
        self.self_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.back_ctx = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=1)
        self.borrowed_payload = UnsafePointer[Payload, MutAnyOrigin](
            unsafe_from_address=1
        )
        self.borrowed_array = UnsafePointer[Int, MutAnyOrigin](unsafe_from_address=1)
        self.alt_scratch = UnsafePointer[Int, MutAnyOrigin](unsafe_from_address=1)
        self.corrupt = False


def array_ok(p: UnsafePointer[Int, MutAnyOrigin]) -> Bool:
    var i = 0
    while i < PATTERN_LEN:
        if p[i] != 1000 + i:
            return False
        i += 1
    return True


@export("t2_alt_entry")
def alt_entry(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[Frame]()

    # Write through the borrow into MAIN's stack before suspending.
    fp[].borrowed_payload[].value = 4242
    fp[].borrowed_array[0] = 1000

    # A stack-backed value of our own (ALT stack) held across the switch.
    var local = Payload(7, 700)
    var local_p = UnsafePointer[Payload, MutAnyOrigin](to=local)

    fp[].alt_scratch[] = 111
    ms_context_switch(fp[].self_ctx, fp[].back_ctx)

    # Resumed: borrows must still point at live, intact MAIN-stack storage.
    if fp[].borrowed_payload[].value != 4242 or not array_ok(fp[].borrowed_array):
        fp[].corrupt = True
    # Our own synthetic-stack local must be untouched by the switch.
    if local_p[].tag != 7 or local_p[].value != 700:
        fp[].corrupt = True


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

        # Stack-backed Mojo values on MAIN's stack, referenced across the switch.
        var payload = Payload(3, 33)
        var pattern = InlineArray[Int, PATTERN_LEN](fill=0)
        var i = 0
        while i < PATTERN_LEN:
            pattern[i] = 1000 + i
            i += 1
        var alt_scratch: Int = 0

        var frame = Frame()
        frame.self_ctx = alt_ctx
        frame.back_ctx = main_ctx
        frame.borrowed_payload = UnsafePointer[Payload, MutAnyOrigin](to=payload)
        frame.borrowed_array = UnsafePointer[Int, MutAnyOrigin](to=pattern[0])
        frame.alt_scratch = UnsafePointer[Int, MutAnyOrigin](to=alt_scratch)
        var frame_p = UnsafePointer[Frame, MutAnyOrigin](to=frame).bitcast[Byte]()

        ms_context_make(
            alt_ctx, stack.guard_low_address(), stack.top_address(),
            entry_pointer["t2_alt_entry"](), frame_p,
        )
        ms_context_switch(main_ctx, alt_ctx)

        # After resume: ALT's write through its borrow must have landed here.
        if payload.value != 4242 or pattern[0] != 1000:
            ok = False
            reason = "borrowed reference into main stack broken after switch"
        if alt_scratch != 111:
            ok = False
            reason = "main could not observe alt-stack writeback"

        ms_context_switch(main_ctx, alt_ctx)  # final resume; callback then returns

        if frame.corrupt:
            ok = False
            reason = "alternate context saw corrupted borrowed references"
        if not array_ok(UnsafePointer[Int, MutAnyOrigin](to=pattern[0])):
            ok = False
            reason = "pattern array corrupted after full round trip"

        # `stack` drops here (NativeStack.__del__ releases it exactly
        # once); no explicit free call needed.

    print("T2 borrowed-reference validity: " + ("PASS" if ok else "FAIL (" + reason + ")"))
    if not ok:
        raise Error("T2 failed: " + reason)
