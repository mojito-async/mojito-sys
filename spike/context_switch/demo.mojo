# S0 spike smoke demo (issue #10).
#
# Runs against libmojito_spike.dylib via the frozen bindings in
# mojito_spike.mojo. The dylib is chosen at link time:
#
#   mojo run -Xlinker <path>/libmojito_spike.dylib spike/context_switch/demo.mojo

from std.memory import stack_allocation

from mojito_spike import (
    BytePtr,
    ms_page_size,
    ms_stack_alloc,
    ms_stack_free,
    ms_stack_total_size,
)


def main():
    var ps = Int(ms_page_size())
    print("page size:", ps)

    # Out-slots handed to ms_stack_alloc; C writes the base/top pointers here.
    var slots = stack_allocation[2, BytePtr]()
    var rc = ms_stack_alloc(2 * ps, slots, slots + 1)
    if rc == 0:
        print("stack alloc ok; base:", slots[], "top:", (slots + 1)[])
        ms_stack_free(slots[])
        print("stack free ok")
    else:
        print("ms_stack_alloc failed with rc", rc)

    print("total reserved:", ms_stack_total_size())
