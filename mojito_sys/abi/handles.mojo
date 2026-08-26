# mojito-sys S1 ABI — opaque native handles (issue #27).
#
# Spec §7.2 (opaque handles).  This is the ONLY definition that remains in
# abi/: it is a raw pointer-sized view used by the earliest S1 lanes.
#
# Placement note (spec §4): the fd ownership wrappers migrated verbatim up
# to mojito_sys/io/handle.mojo in issue #42; their semantics are unchanged
# by that move.  The sentinel and the platform close binding moved with
# them.
#
# Ownership model (public contract):
#   - OpaqueNativeHandle is a raw pointer-sized handle to native state the
#     wrapper does not own.  It exposes a null sentinel (address 0) and a
#     pointer() that COPIES the address; the caller must not retain or free
#     the referent through it.

from std.memory.unsafe_pointer import UnsafePointer

comptime HandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
#
# Origin choice (issue #45): this is EXACTLY spec §7.2's sketch and matches
# sibling UserdataPtr (callbacks.mojo).  MutUntrackedOrigin is correct here
# because HandlePtr never occupies an extern out-slot — the module's only
# @extern is ms_close(Int32).  The MutAnyOrigin out-slot doctrine documented
# in virtual_memory.mojo/stack.mojo (an UntrackedOrigin slot load can be
# hoisted ABOVE an opaque callee) applies only to pointers handed across an
# extern boundary; OpaqueNativeHandle never crosses one.


# ---------------------------------------------------------------------------
# OpaqueNativeHandle — a raw native pointer with no ownership.
# ---------------------------------------------------------------------------
struct OpaqueNativeHandle:
    var ptr: HandlePtr

    # A default handle is null (the address-0 sentinel).
    def __init__(out self):
        var zero: Int = 0
        self.ptr = HandlePtr(unsafe_from_address=zero)

    # Wrap an existing non-null native pointer (no ownership transfer).
    def __init__(out self, p: HandlePtr):
        self.ptr = p

    # True when this handle holds the null sentinel (address 0).
    def is_null(self) -> Bool:
        return Int(self.ptr) == 0

    # Returns the raw address.  This is a COPY, not a transfer: the caller
    # must not keep or free the referent through the returned pointer.
    def pointer(self) -> HandlePtr:
        return self.ptr
