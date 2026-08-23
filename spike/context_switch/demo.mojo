# S0 spike smoke demo (issue #10).
#
# Exercises the libmojito_spike.dylib surface from Mojo via @extern
# declarations. This file intentionally carries its own declarations in the
# RED phase so it fails at link/load time while no dylib exists yet; once the
# binding module lands these move to mojito_spike.mojo.

from std.memory import stack_allocation


@extern("ms_page_size")
def ms_page_size() abi("C") -> Int32:
    ...


@extern("ms_stack_alloc")
def ms_stack_alloc(
    bytes: Int,
    out_base: UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutUntrackedOrigin],
    out_top: UnsafePointer[UnsafePointer[Byte, MutAnyOrigin], MutUntrackedOrigin],
) abi("C") -> Int32:
    ...


@extern("ms_stack_free")
def ms_stack_free(base: UnsafePointer[Byte, MutAnyOrigin]) abi("C"):
    ...


@extern("ms_stack_total_size")
def ms_stack_total_size() abi("C") -> Int:
    ...


def main():
    var ps = Int(ms_page_size())
    print("page size:", ps)

    # Out-slots handed to ms_stack_alloc; C writes the base/top pointers here.
    var slots = stack_allocation[2, UnsafePointer[Byte, MutAnyOrigin]]()
    var rc = ms_stack_alloc(2 * ps, slots, slots + 1)
    if rc == 0:
        print("stack alloc ok; base:", slots[], "top:", (slots + 1)[])
        ms_stack_free(slots[])
        print("stack free ok")
    else:
        print("ms_stack_alloc failed with rc", rc)

    print("total reserved:", ms_stack_total_size())
