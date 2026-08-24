# callbacks.mojo — C-ABI callback token (mojito-sys S1, issue #32).
#
# Standardizes the native callback shape from spec section 8:
#
#     typedef void (*ms_callback)(void *userdata);
#
# Mojo 1.0.0b2 cannot express a raw C function pointer as a comptime alias /
# struct field: function types here are nominal and every UnsafePointer-based
# fn-pointer conversion is rejected (see S0 SPIKE_REPORT). This lane therefore
# fixes ONLY the token half of the shape — the opaque descriptor a caller
# stores and passes to native code. The callback itself stays a
# `def ... abi("C")` (lowered to the C ABI) addressed by its machine pointer;
# those are the spike-lane's concern.
#
# The token is a POD pair of machine-word address slots. It is NOT a function
# pointer and MUST NOT be invoked from Mojo; it exists to be carried across
# the C ABI firewall and resolved by native trampoline code.
#
# LIFETIME + OWNERSHIP RULES (mirrors spec §8):
#   * native code MUST NOT retain temporary Mojo pointers without an explicit
#     lifetime contract;
#   * cross-thread callbacks entering Mojo MUST follow any runtime
#     initialization/attachment requirements documented by Mojo;
#   * callback ownership and destruction MUST be explicit;
#   * stack-borrowing callbacks MUST remain synchronous unless lifetime is
#     statically guaranteed.
#   When native code holds a token (or the userdata it registers), the
#   descriptor and any borrowed Mojo pointer remain valid for at least the
#   registration's lifetime; a token that outlives its registration is a
#   dangling descriptor.
#
# NULLABILITY (b2): `UnsafePointer` is a NON-NULLABLE type — a literal
# `unsafe_from_address=0` is a compile error ("UnsafePointer is non-nullable").
# The supported construction paths supply the address as a comptime const or
# a runtime value, both of which admit zero (verified in this lane). We do NOT
# model the slot with an `Optional[UnsafePointer]`: Optional is a tagged
# wrapper whose layout is not a bare machine word, so it would break the C
# `void*` field shape of the token. `unset()` centralizes legal null
# construction.

from std.memory import UnsafePointer

# C `void*` has no `Void` type in Mojo; the pointee type is a formality for
# the address slot. `NoneType` is the stdlib convention for an untracked C
# pointer target.
comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]

# Address slot of the callback's code (function) pointer.
comptime VoidPtr = UnsafePointer[NoneType, MutAnyOrigin]

# Opaque userdata carrier passed to native code. `NoneType` pointee: the slot
# is an address, never dereferenced through this type; native code interprets
# the raw address per its own ABI. `MutUntrackedOrigin` signals a raw foreign
# address Mojo does not track or dereference.
comptime UserdataPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


struct CallbackToken:
    # Resolved machine address of the target callback (0 = null token).
    var addr: VoidPtr
    # Opaque userdata delivered back to the callback (0 allowed).
    var userdata: UserdataPtr

    def __init__(
        out self,
        addr: VoidPtr,
        userdata: UserdataPtr,
    ):
        self.addr = addr
        self.userdata = userdata

    # Null token (no callback). Centralizes the b2-legal null construction:
    # a comptime/runtime-sourced zero address.
    @staticmethod
    def unset() -> CallbackToken:
        var zero = 0
        return CallbackToken(
            VoidPtr(unsafe_from_address=zero),
            UserdataPtr(unsafe_from_address=zero),
        )

    # Token for a callback whose code pointer originates from a `BytePtr`
    # (e.g. the spike's `entry_pointer`). The slot is re-typed to `VoidPtr`
    # without a dereference — a pure address projection; b2's nominal pointer
    # types reject unsafe casts, and bitcast preserves the numeric address
    # exactly (conformance asserts this).
    @staticmethod
    def from_code_pointer(addr: BytePtr, userdata: UserdataPtr) -> CallbackToken:
        return CallbackToken(addr.bitcast[NoneType](), userdata)

    # Nullity is callback-address nullity: a token is null iff its callback
    # function address is zero. A userdata slot on a null address is retained
    # but explicitly ignored by native code that checks the address first.
    def is_null(self) -> Bool:
        return Int(self.addr) == 0

    # NOTE: a token passed to live native code holds both slots by raw
    # address. Do NOT reassign `addr`/`userdata` while the token is registered
    # with code that captures it; mutate only an unregistered/scratch token.
