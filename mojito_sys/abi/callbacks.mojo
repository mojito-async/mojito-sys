# callbacks.mojo — C-ABI callback token (mojito-sys S1, issue #32).
#
# Standardizes the native callback shape from spec section 8:
#
#     typedef void (*ms_callback)(void *userdata);
#
# Mojo 1.0.0b2 cannot express a raw C function pointer as a comptime alias /
# struct field: function types here are nominal, and every UnsafePointer-based
# fn-pointer conversion is rejected (see S0 SPIKE_REPORT). This lane therefore
# fixes ONLY the token half of the shape — the opaque descriptor a caller
# stores and passes to native code. The callback itself stays a Mojo
# `def ... abi("C")` (lowered to the C ABI) addressed by its machine pointer;
# those are the spike-lane's concern.
#
# The token is a plain pair of machine-word address slots (POD). It is NOT
# a function pointer and MUST NOT be invoked from Mojo; it exists to be
# carried across the C ABI firewall and resolved by native trampoline code.
#
# S1 LIFETIME RULES (spec §8) — binding authors MUST respect these:
#   * native code MUST NOT retain temporary Mojo pointers without an explicit
#     lifetime contract (stack addresses are volatile across transfers);
#   * stack-borrowing callbacks MUST remain synchronous unless their lifetime
#     is statically guaranteed — never queue a callback that borrows Mojo
#     stack locals for a later thread;
#   * cross-thread callbacks entering Mojo MUST follow any runtime
#     initialization/attachment requirements documented by Mojo;
#   * callback ownership and destruction MUST be explicit — a token that
#     outlives its registration is a dangling descriptor.

from std.memory import UnsafePointer

# C `void*` has no `Void` type in Mojo; the pointee type is a formality for
# the address slot. `NoneType` is the stdlib convention for an arbitrary /
# untracked C pointer target.
comptime VoidPtr = UnsafePointer[NoneType, MutAnyOrigin]

# Opaque userdata carrier passed to native code. `NoneType` pointee because
# the slot is an address, never dereferenced through this type. The token is
# a descriptor only; native code interprets the raw address per its own ABI.
comptime UserdataPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


struct CallbackToken:
    # Resolved machine address of the target callback (0 = none yet).
    var addr: VoidPtr
    # Opaque userdata delivered back to the callback. `MutAnyOrigin` would
    # also be defensible; `MutUntrackedOrigin` signals this slot holds a raw
    # foreign address Mojo does not track or dereference.
    var userdata: UserdataPtr

    def __init__(
        out self,
        addr: VoidPtr,
        userdata: UserdataPtr,
    ):
        self.addr = addr
        self.userdata = userdata

    # A token is null when its function address is zero (C null pointer).
    def is_null(self) -> Bool:
        return Int(self.addr) == 0

    # Numeric address of the userdata slot — the round-trip value native code
    # receives back. Exposed so tokens can be inspected/asserted without a
    # dereference (the pointee of `userdata` is intentionally opaque here).
    def userdata_addr(self) -> Int:
        return Int(self.userdata)