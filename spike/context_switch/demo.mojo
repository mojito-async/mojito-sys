# S0 spike smoke demo (issue #10).
#
# Exercises the FULL libmojito_spike.dylib surface from Mojo via the frozen
# bindings in mojito_spike.mojo:
#   - page-size query
#   - guarded stack alloc/free round trip with total-size invariants
#   - a REAL context switch: an @export'd abi("C") Mojo callback runs on the
#     synthetic stack (entered through the C trampoline), yields back to
#     main with ms_ctx_switch, is resumed, and exits through the trampoline.
#
# The dylib is chosen at link time:
#   mojo run -Xlinker <path>/libmojito_spike.dylib spike/context_switch/demo.mojo

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
    ms_stack_total_size,
)


struct DemoFrame:
    var alt_ctx: BytePtr
    var main_ctx: BytePtr
    var rounds: Int

    def __init__(out self, ac: BytePtr, mc: BytePtr):
        self.alt_ctx = ac
        self.main_ctx = mc
        self.rounds = 0


# Trampoline entry: runs on the synthetic stack with AAPCS64 calling
# convention (x0 = userdata). Yields once, then returns; the exit trampoline
# switches back to the recorded return context (main).
@export("mojito_demo_entry")
def demo_entry(ud: BytePtr) abi("C"):
    var f = ud.bitcast[DemoFrame]()
    f[].rounds += 1
    if f[].rounds == 1:
        ms_ctx_switch(f[].alt_ctx, f[].main_ctx)
        f[].rounds += 1


def check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var ps = Int(ms_page_size())
    print("page size:", ps)
    check(ps > 0, "ms_page_size returned non-positive value")

    # Out-slots handed to ms_stack_alloc; C writes the base/top pointers here.
    var slots = stack_allocation[2, BytePtr]()

    var rc = ms_stack_alloc(2 * ps, slots, slots + 1)
    check(rc == 0, "ms_stack_alloc failed with rc " + String(rc))
    print("stack alloc ok; base:", slots[], "top:", (slots + 1)[])

    # Reserved total = usable pages + one guard page while allocation lives.
    check(
        ms_stack_total_size() == 3 * ps,
        "total reserved during alloc should be 3*page (got "
        + String(ms_stack_total_size()) + ")",
    )

    # ---- real context switch through the C trampoline -------------------
    var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
    var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
    var main_ctx = main_buf.bitcast[Byte]()
    var alt_ctx = alt_buf.bitcast[Byte]()

    var fs = stack_allocation[1, DemoFrame]()
    fs[] = DemoFrame(alt_ctx, main_ctx)

    ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["mojito_demo_entry"](), fs.bitcast[Byte]())

    # Enter ALT: callback runs, increments rounds to 1, yields back here.
    ms_ctx_switch(main_ctx, alt_ctx)
    check(fs[].rounds == 1, "callback did not yield back after first entry")

    # Resume ALT: callback completes and returns; trampoline hands control
    # back to main by itself.
    ms_ctx_switch(main_ctx, alt_ctx)
    check(fs[].rounds == 2, "callback did not complete after resume")
    print("context switch ok; callback rounds:", fs[].rounds)

    ms_stack_free(slots[])
    print("stack free ok")

    check(ms_stack_total_size() == 0, "total reserved after free should be 0")
    print("total reserved:", ms_stack_total_size())
