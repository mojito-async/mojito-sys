# Mojo bindings for libmojito_spike.dylib — S0 spike (issue #10).
#
# This is the b2-legal formulation of the frozen binding names from
# spike/context_switch/CONTRACT.md ("Mojo bindings — AMENDED per #16") for
# Mojo 1.0.0b2 (2cf4d08a):
#
#   - The C-style function-declaration keyword is `def`; `fn` is removed.
#   - External symbols are declared with `@extern("<c_symbol>")` plus an
#     explicit `abi("C")` effect between the parameter list and the result
#     type, and a `...` body. The decorator takes exactly one argument (the
#     symbol); the library is chosen at link time (-Xlinker <dylib>), not in
#     the decorator.
#   - UnsafePointer carries mutability/origin parameters that must be
#     concrete in extern signatures (origin inference has no call-site
#     context there). Pointers written by C into caller storage are spelled
#     with `MutAnyOrigin`; scratch out-slot storage allocated via
#     std.memory.stack_allocation is `MutUntrackedOrigin`.
#
# Link with:  mojo run -Xlinker <path>/libmojito_spike.dylib demo.mojo

comptime LIB = "libmojito_spike.dylib"

comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]

# Pointer to caller-provided storage holding one BytePtr each; this is what
# ms_stack_alloc writes *out_base / *out_top through.
comptime OutSlots = UnsafePointer[BytePtr, MutUntrackedOrigin]


@extern("ms_page_size")
def ms_page_size() abi("C") -> Int32:
    ...


@extern("ms_stack_alloc")
def ms_stack_alloc(
    bytes: Int,
    out_base: OutSlots,
    out_top: OutSlots,
) abi("C") -> Int32:
    ...


@extern("ms_stack_free")
def ms_stack_free(base: BytePtr) abi("C"):
    ...


@extern("ms_stack_total_size")
def ms_stack_total_size() abi("C") -> Int:
    ...


@extern("ms_ctx_make")
def ms_ctx_make(
    ctx: BytePtr,
    stack_top: BytePtr,
    entry: BytePtr,
    userdata: BytePtr,
) abi("C"):
    ...


@extern("ms_ctx_switch")
def ms_ctx_switch(from_: BytePtr, to: BytePtr) abi("C"):
    ...
