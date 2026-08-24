# S1-ABI-CALLBACKS-T1 — callback token nullity + userdata round-trip
# (mojito-sys #32).
#
# Validates CallbackToken semantics against spec section 8:
#   * a zero address is a null token;
#   * a nonzero address is a live token;
#   * userdata is an opaque address slot that round-trips its value through
#     the token unchanged.
#
# No native library is involved: the token is a POD descriptor, so this test
# exercises only token construction, nullity, and address round-trip.

from std.memory import UnsafePointer
from mojito_sys.abi.callbacks import CallbackToken, VoidPtr, UserdataPtr

# Comptime-generated null address: the C null pointer.
comptime NULL_ADDR: Int = 0
# A nonzero live address for the function slot (arbitrary; never invoked).
comptime LIVE_ADDR: Int = 1

def main() raises:
    var ok = True
    var reason = "ok"

    # --- null token -----------------------------------------------------
    var null_tok = CallbackToken(
        UnsafePointer[NoneType, MutAnyOrigin](unsafe_from_address=NULL_ADDR),
        UnsafePointer[NoneType, MutUntrackedOrigin](unsafe_from_address=NULL_ADDR),
    )
    if not null_tok.is_null():
        ok = False
        reason = "zero-address token not is_null()"
        print("  + token addr=" + String(Int(null_tok.addr)))

    # ---- live token, null userdata -------------------------------------
    var live_tok = CallbackToken(
        UnsafePointer[NoneType, MutAnyOrigin](unsafe_from_address=LIVE_ADDR),
        UnsafePointer[NoneType, MutUntrackedOrigin](unsafe_from_address=NULL_ADDR),
    )
    if live_tok.is_null():
        ok = False
        reason = "nonzero-address token reported is_null()"

    # ---- userdata round-trip through a real variable --------------------
    var tag: Int = 424242
    var tag_ptr = UnsafePointer[Int, MutAnyOrigin](to=tag)
    var ud_addr: Int = Int(tag_ptr)
    var ud = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=ud_addr
    )
    var rt_tok = CallbackToken(
        UnsafePointer[NoneType, MutAnyOrigin](unsafe_from_address=LIVE_ADDR),
        ud,
    )
    if rt_tok.userdata_addr() != ud_addr:
        ok = False
        reason = (
            "userdata addr mismatch: stored "
            + String(ud_addr)
            + ", token reports "
            + String(rt_tok.userdata_addr())
        )
    else:
        # The token still addresses the live variable: dereference through a
        # bitcast and confirm the round-tripped value is intact.
        var back = rt_tok.userdata.bitcast[Int]()
        if back[] != tag:
            ok = False
            reason = (
                "userdata deref mismatch: stored "
                + String(tag)
                + ", read "
                + String(back[])
            )

    print(
        "S1-ABI-CALLBACKS-T1 conformance: "
        + ("PASS" if ok else "FAIL (" + reason + ")")
    )
    if not ok:
        raise Error("S1-ABI-CALLBACKS-T1 failed: " + reason)