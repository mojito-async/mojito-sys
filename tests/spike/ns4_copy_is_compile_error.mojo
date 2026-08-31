# NS4 -- double release is impossible BY CONSTRUCTION: an implicit copy of
# NativeStack must fail to compile (mojito-sys #128, memory half).
#
# This file is NOT meant to compile. tests/spike/ns4_check.sh drives it and
# treats a COMPILE FAILURE containing the expected diagnostic as the PASS
# condition for NS4; a clean compile here would mean NativeStack somehow
# became copyable and is the actual FAILURE mode this test exists to catch.
#
# NativeStack conforms to Movable only (spike/stack_switch/native_stack.mojo)
# and defines no `__init__(out self, *, copy: Self)` / `__copyinit__`, so an
# implicit copy (`var b = a` without `^`) has no legal lowering: two live
# NativeStack values would both believe they own the one mapping, and both
# __del__ would try to munmap it -- the double release this test proves is
# unreachable, not merely undocumented.

from native_stack import NativeStack


def main() raises:
    var s = NativeStack.create(65536, 0, 4096)
    var copy_of_s = s  # EXPECTED COMPILE ERROR: cannot be implicitly copied
    print(copy_of_s.base_address())
