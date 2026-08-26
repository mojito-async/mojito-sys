# S1-ABI-CALLBACKS-T1 — callback token nullity + userdata round-trip
# (mojito-sys #32).
#
# Validates CallbackToken against spec section 8 and the C-side frozen
# layout (struct mjs_callback_token { void *addr; void *userdata; }, which
# lands in the S1Build header):
#   * unset() yields a null token (nullity is callback-address nullity);
#   * a live token materialized from a real @export abi("C") function
#     address (spike entry_pointer pattern) is non-null and keeps that
#     address exactly;
#   * userdata is an opaque address slot that round-trips unchanged;
#   * a userdata slot on a null address is retained but ignored for
#     nullity (M1);
#   * the token projects to two raw machine words (addr, userdata) matching
#     m2i_callback_token and reassembles without loss (H3).
#
# Since #43, the native layout sink exists: driver.c (same directory,
# linked by run.sh) static-asserts sizeof(mjs_callback_token)==16 with
# addr at 0 / userdata at 8, and drives C-to-Mojo invokes through the
# T2 sections below.
#
# b2 COMPILE-CAPABILITY NOTE: `UnsafePointer[...]` is non-nullable in
# 1.0.0b2 — a literal `unsafe_from_address=0` is a compile error. Null
# construction therefore goes through `CallbackToken.unset()` (comptime /
# runtime-sourced zero), never a literal zero. Verified: literal zero is
# rejected; runtime/comptime zero compiles.

from std.memory import UnsafePointer, stack_allocation
from std.sys.intrinsics import inlined_assembly
from mojito_sys.abi.callbacks import (
    BytePtr,
    CallbackToken,
    UserdataPtr,
    VoidPtr,
)

# Arbitrary nonzero userdata tag for the null-address case (M1).
comptime TAG_ADDR: Int = 0x1234


@export("cb_target")
def cb_target(userdata: UserdataPtr) abi("C"):
    pass


# --- S1.10 (#43): C-to-Mojo invoke conformance ------------------------------
#
# The native half (driver.c, same directory) is linked into this executable
# by run.sh via -Xlinker. It receives the two-word token projected below,
# casts the addr slot to ms_callback and invokes INTO this module's
# @export abi("C") callback, which writes SENTINEL through the opaque
# userdata pointer.

comptime SENTINEL: Int = 0x5E17A1C0


@export("mjs_abi_cb_sentinel")
def mjs_abi_cb_sentinel(userdata: UserdataPtr) abi("C"):
    # C driver invokes us as `void (*)(void *)`: write through userdata.
    (userdata.bitcast[Int]())[] = SENTINEL


# Driver entry points (driver.c); linked via -Xlinker, resolved at static
# link time. Raw addresses handed to / received from C use MutAnyOrigin.
comptime DrvTokenPtr = UnsafePointer[Byte, MutAnyOrigin]


@extern("mjs_abi_cbdrv_invoke")
def cbdrv_invoke(token: DrvTokenPtr) abi("C") -> Int32:
    ...


@extern("mjs_abi_cbdrv_invoke_corrupt")
def cbdrv_invoke_corrupt(token: DrvTokenPtr, mode: Int32) abi("C") -> Int32:
    ...


# Spike's entry_pointer: materialize the machine address of an @export
# abi("C") function as a BytePtr (adrp/add pair), mirroring the real C ABI
# path a callback address arrives through.
def entry_pointer[symbol_name: String]() -> BytePtr:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return BytePtr(unsafe_from_address=Int(addr))


def main() raises:
    var ok = True
    var reason = "ok"

    # --- H2: null token via the unset() factory ------------------------------
    var null_tok = CallbackToken.unset()
    if not null_tok.is_null():
        ok = False
        reason = "unset() token not is_null()"
        print("  + unset addr=" + String(Int(null_tok.addr)))

    # --- M5: live token from a real code address -----------------------------
    var code = entry_pointer["cb_target"]()
    var zero = 0
    var ud0 = UserdataPtr(unsafe_from_address=zero)
    var live_tok = CallbackToken.from_code_pointer(code, ud0)
    if live_tok.is_null():
        ok = False
        reason = "code-address token reported is_null()"
    elif Int(live_tok.addr) != Int(code):
        ok = False
        reason = (
            "code-address mismatch: materialized "
            + String(Int(code))
            + ", token "
            + String(Int(live_tok.addr))
        )

    # --- userdata round-trip through a live variable ---------------------------
    var tag: Int = 424242
    var tag_addr: Int = Int(UnsafePointer[Int, MutAnyOrigin](to=tag))
    var ud = UserdataPtr(unsafe_from_address=tag_addr)
    var rt_tok = CallbackToken(
        live_tok.addr,
        ud,
    )
    if Int(rt_tok.userdata) != tag_addr:
        ok = False
        reason = (
            "userdata addr mismatch: stored "
            + String(tag_addr)
            + ", token "
            + String(Int(rt_tok.userdata))
        )
    else:
        # The token still addresses the live variable: dereference confirms
        # the round-tripped value is intact.
        var back = rt_tok.userdata.bitcast[Int]()
        if back[] != tag:
            ok = False
            reason = (
                "userdata deref mismatch: stored "
                + String(tag)
                + ", read "
                + String(back[])
            )

    # --- M1: userdata on a null address is retained but ignored ---------------
    var m1 = CallbackToken.unset()
    m1.userdata = UserdataPtr(unsafe_from_address=TAG_ADDR)
    if not m1.is_null():
        ok = False
        reason = "userdata-on-null made token live"
    else:
        # Retained but ignored: nullity still true, slot value preserved.
        if Int(m1.userdata) != TAG_ADDR:
            ok = False
            reason = "userdata on null not retained"

    # --- H3: two-word raw projection (mjs_callback_token shape) --------------
    var w0 = Int(rt_tok.addr)
    var w1 = Int(rt_tok.userdata)
    var rebuilt = CallbackToken(
        VoidPtr(unsafe_from_address=w0),
        UserdataPtr(unsafe_from_address=w1),
    )
    if Int(rebuilt.addr) != w0 or Int(rebuilt.userdata) != w1:
        ok = False
        reason = (
            "two-word projection lost data: ("
            + String(Int(rebuilt.addr))
            + ","
            + String(Int(rebuilt.userdata))
            + ") vs raw ("
            + String(w0)
            + ","
            + String(w1)
            + ")"
        )

    var t1_ok = ok
    print(
        "S1-ABI-CALLBACKS-T1 token conformance: "
        + ("PASS" if t1_ok else "FAIL (" + reason + ")")
    )

    # === T2 (#43): C-to-Mojo invoke through the frozen layout ================

    # Live callback address + sentinel cell, projected to the two C words.
    var cell = stack_allocation[1, Int]()
    cell[] = 0
    var cb_code = entry_pointer["mjs_abi_cb_sentinel"]()
    var live_ud = UserdataPtr(unsafe_from_address=Int(cell))
    var tok = CallbackToken.from_code_pointer(cb_code, live_ud)
    var words = stack_allocation[2, Int]()
    words[0] = Int(tok.addr)
    words[1] = Int(tok.userdata)

    # T2a: positive invoke — C casts word0 to ms_callback and calls; the
    # Mojo callback writes SENTINEL through the userdata pointer.
    var rc = Int(cbdrv_invoke(words.bitcast[Byte]()))
    var t2a_ok = rc == 0 and cell[] == SENTINEL
    if not t2a_ok:
        print(
            "  + invoke rc="
            + String(rc)
            + " sentinel="
            + String(cell[])
        )
    print(
        "S1-ABI-CALLBACKS-T2a C->Mojo invoke delivers sentinel: "
        + ("PASS" if t2a_ok else "FAIL")
    )

    # Token immutability: the driver must not disturb either slot.
    var imm_ok = words[0] == Int(tok.addr) and words[1] == Int(tok.userdata)
    print(
        "S1-ABI-CALLBACKS-T2b driver leaves token untouched: "
        + ("PASS" if imm_ok else "FAIL")
    )

    # T2c: corrupted addr slot (NULL) — deterministic refusal (rc=1), no
    # crash, no invocation: nullity is addr-nullity.
    cell[] = 0
    rc = Int(cbdrv_invoke_corrupt(words.bitcast[Byte](), Int32(0)))
    var t2c_ok = rc == 1 and cell[] == 0
    if not t2c_ok:
        print("  + corrupt(NULL) rc=" + String(rc) + " sentinel=" + String(cell[]))
    print(
        "S1-ABI-CALLBACKS-T2c corrupted-NULL addr refused deterministically: "
        + ("PASS" if t2c_ok else "FAIL")
    )

    # T2d: corrupted addr slot (valid-but-wrong code) — dispatch returns
    # normally, sentinel stays absent: a deterministic FAIL surface, not a
    # crash.
    rc = Int(cbdrv_invoke_corrupt(words.bitcast[Byte](), Int32(1)))
    var t2d_ok = rc == 0 and cell[] == 0
    if not t2d_ok:
        print("  + corrupt(benign) rc=" + String(rc) + " sentinel=" + String(cell[]))
    print(
        "S1-ABI-CALLBACKS-T2d corrupted-wrong addr fails deterministically: "
        + ("PASS" if t2d_ok else "FAIL")
    )

    var all_ok = (
        t1_ok and t2a_ok and imm_ok and t2c_ok and t2d_ok
    )
    print("RESULT: " + ("all green" if all_ok else "FAILED"))
    if not all_ok:
        raise Error("S1-ABI-CALLBACKS conformance failed")
