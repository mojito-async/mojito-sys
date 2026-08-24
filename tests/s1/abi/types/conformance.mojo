# mojito-sys S1.2 — ABI C-type alias conformance (issue #25)
#
# Validates the LP64 width table exported by mojito_sys.abi.types on THIS
# host (provenance: Darwin arm64). Conformance against the LP64 table
# documented in the module header, NOT runtime introspection of the
# host C ABI (review PR #34, M1).
# normalized c_* alias exported by mojito_sys.abi.types:
#   1. is a usable type identifier (values construct and re-read);
#   2. has the C ABI width expected on LP64 — proven two ways:
#        a. CTypeSizes dtype oracle (alias.dtype -> DType -> byte width)
#        b. conversion semantics (out-of-range literal round-trips prove
#           the exact storage width, e.g. c_int(2^32) == 0 means 4-byte
#           signed storage)
#   3. is valid in function signatures (plain def; the abi("C") extern
#      grammar is the same, but this checks the type grammar only).
#
# Pure Mojo: no native code, no extern, no allocation. On any FAIL the
# process prints the row and exits nonzero (raise).

from mojito_sys.abi.types import (
    c_char, c_short, c_int, c_long, c_long_long,
    c_uchar, c_ushort, c_uint, c_ulong, c_ulong_long,
    c_size_t, c_ssize_t, c_float, c_double, c_pid_t,
    c_int8, c_uint8, c_int16, c_uint16, c_int32, c_uint32,
    c_int64, c_uint64, c_intptr_t, c_uintptr_t, c_bool,
    CTypeSizes,
)

comptime C32 = 0x1_0000_0000         # 2^32
comptime WIDE = 0x1_0000_0000_0000   # 2^48, needs 64-bit storage

# Signature grammar: c_* aliases in a plain def signature.
def c_abi_signature(a: c_int, b: c_size_t) -> c_long_long:
    return c_long_long(a) + c_long_long(b)


def check(name: String, cond: Bool) -> Bool:
    print(name + " " + ("PASS" if cond else "FAIL"))
    return cond


def main() raises:
    var total = 0
    var fails = 0

    # 1. type-usable: construct a value & re-read it through Int()
    var v_char: c_char = c_char(0x61)
    var v_uchar: c_uchar = c_uchar(0xFF)
    var v_short: c_short = c_short(-2)
    var v_ushort: c_ushort = c_ushort(2)
    var v_int: c_int = c_int(-3)
    var v_uint: c_uint = c_uint(3)
    var v_long: c_long = c_long(-4)
    var v_ulong: c_ulong = c_ulong(4)
    var v_llong: c_long_long = c_long_long(-5)
    var v_ull: c_ulong_long = c_ulong_long(5)
    var v_sz: c_size_t = c_size_t(6)
    var v_szt: c_ssize_t = c_ssize_t(-6)
    var v_float: c_float = c_float(1.5)
    var v_double: c_double = c_double(2.5)
    var v_pid: c_pid_t = c_pid_t(7)
    var v_i8: c_int8 = c_int8(-8)
    var v_u8: c_uint8 = c_uint8(8)
    var v_i16: c_int16 = c_int16(-9)
    var v_u16: c_uint16 = c_uint16(9)
    var v_i32: c_int32 = c_int32(-10)
    var v_u32: c_uint32 = c_uint32(10)
    var v_i64: c_int64 = c_int64(-11)
    var v_u64: c_uint64 = c_uint64(11)
    var v_iptr: c_intptr_t = c_intptr_t(12)
    var v_uiptr: c_uintptr_t = c_uintptr_t(12)
    var v_bool: c_bool = c_bool(True)

    # 1. type-usable: construct and re-read every alias
    total += 1
    if not check("type-usable char", Int(v_char) == 0x61):
        fails += 1
    total += 1
    if not check("type-usable uchar", Int(v_uchar) == 0xFF):
        fails += 1
    total += 1
    if not check("type-usable short", Int(v_short) == -2):
        fails += 1
    total += 1
    if not check("type-usable ushort", Int(v_ushort) == 2):
        fails += 1
    total += 1
    if not check("type-usable int", Int(v_int) == -3):
        fails += 1
    total += 1
    if not check("type-usable uint", Int(v_uint) == 3):
        fails += 1
    total += 1
    if not check("type-usable long", Int(v_long) == -4):
        fails += 1
    total += 1
    if not check("type-usable ulong", Int(v_ulong) == 4):
        fails += 1
    total += 1
    if not check("type-usable long-long", Int(v_llong) == -5):
        fails += 1
    total += 1
    if not check("type-usable ulong-long", Int(v_ull) == 5):
        fails += 1
    total += 1
    if not check("type-usable size-t", Int(v_sz) == 6):
        fails += 1
    total += 1
    if not check("type-usable ssize-t", Int(v_szt) == -6):
        fails += 1
    total += 1
    if not check("type-usable pid-t", Int(v_pid) == 7):
        fails += 1
    total += 1
    if not check("type-usable int8", Int(v_i8) == -8):
        fails += 1
    total += 1
    if not check("type-usable uint8", Int(v_u8) == 8):
        fails += 1
    total += 1
    if not check("type-usable int16", Int(v_i16) == -9):
        fails += 1
    total += 1
    if not check("type-usable uint16", Int(v_u16) == 9):
        fails += 1
    total += 1
    if not check("type-usable int32", Int(v_i32) == -10):
        fails += 1
    total += 1
    if not check("type-usable uint32", Int(v_u32) == 10):
        fails += 1
    total += 1
    if not check("type-usable int64", Int(v_i64) == -11):
        fails += 1
    total += 1
    if not check("type-usable uint64", Int(v_u64) == 11):
        fails += 1
    total += 1
    if not check("type-usable intptr", Int(v_iptr) == 12):
        fails += 1
    total += 1
    if not check("type-usable uintptr", Int(v_uiptr) == 12):
        fails += 1
    total += 1
    if not check("type-usable bool", v_bool == True):
        fails += 1

    # 2. width oracle reads the ALIAS dtype (review H1) — LP64 table
    total += 1
    if not check("width int8 1", CTypeSizes.int8() == 1):
        fails += 1
    total += 1
    if not check("width uint8 1", CTypeSizes.uint8() == 1):
        fails += 1
    total += 1
    if not check("width int16 2", CTypeSizes.int16() == 2):
        fails += 1
    total += 1
    if not check("width uint16 2", CTypeSizes.uint16() == 2):
        fails += 1
    total += 1
    if not check("width int32 4", CTypeSizes.int32() == 4):
        fails += 1
    total += 1
    if not check("width uint32 4", CTypeSizes.uint32() == 4):
        fails += 1
    total += 1
    if not check("width int64 8", CTypeSizes.int64() == 8):
        fails += 1
    total += 1
    if not check("width uint64 8", CTypeSizes.uint64() == 8):
        fails += 1
    total += 1
    if not check("width float32 4", CTypeSizes.float32() == 4):
        fails += 1
    total += 1
    if not check("width float64 8", CTypeSizes.float64() == 8):
        fails += 1
    total += 1
    if not check("width size-t 8", CTypeSizes.size_t() == 8):
        fails += 1
    total += 1
    if not check("width long 8", CTypeSizes.long() == 8):
        fails += 1
    total += 1
    if not check("width ulong 8", CTypeSizes.ulong() == 8):
        fails += 1
    total += 1
    if not check("width pid-t 4", CTypeSizes.pid_t() == 4):
        fails += 1
    total += 1
    if not check("width bool 1", CTypeSizes.bool() == 1):
        fails += 1

    # 3. conversion semantics prove the exact storage width
    total += 1
    if not check("conv int8 1b", Int(c_int8(0xFF)) == -1):
        fails += 1
    total += 1
    if not check("conv uint8 1b", Int(c_uint8(256)) == 0):
        fails += 1
    total += 1
    if not check("conv int16 2b", Int(c_int16(0xFFFF)) == -1):
        fails += 1
    total += 1
    if not check("conv uint16 2b", Int(c_uint16(0x10000)) == 0):
        fails += 1
    total += 1
    if not check("conv int32 4b", Int(c_int32(C32)) == 0):
        fails += 1
    total += 1
    if not check("conv uint32 4b", Int(c_uint32(C32 + 1)) == 1):
        fails += 1
    total += 1
    if not check("conv int64 8b", Int(c_int64(WIDE)) == WIDE):
        fails += 1
    total += 1
    if not check("conv uint64 8b", Int(c_uint64(0x1_0000_0000_0000_0001)) == 1):
        fails += 1
    total += 1
    if not check("conv float32", Float32(c_float(1.5)) == 1.5):
        fails += 1
    total += 1
    if not check("conv float64", Float64(c_double(2.5)) == 2.5):
        fails += 1
    total += 1
    if not check("conv pid-t 4b", Int(c_pid_t(C32)) == 0):
        fails += 1
    total += 1
    if not check("conv char 1b", Int(c_char(0x1FF)) == -1):
        fails += 1
    total += 1
    if not check("conv uchar 1b", Int(c_uchar(256)) == 0):
        fails += 1
    total += 1
    if not check("conv short 2b", Int(c_short(0xFFFF)) == -1):
        fails += 1
    total += 1
    if not check("conv ushort 2b", Int(c_ushort(0x10000)) == 0):
        fails += 1
    total += 1
    if not check("conv int 4b", Int(c_int(C32)) == 0):
        fails += 1
    total += 1
    if not check("conv uint 4b", Int(c_uint(C32 + 1)) == 1):
        fails += 1
    total += 1
    if not check("conv longlong 8b", Int(c_long_long(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv ulonglong 8b", Int(c_ulong_long(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv size-t 8b", Int(c_size_t(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv ssize-t 8b", Int(c_ssize_t(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv long 8b", Int(c_long(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv ulong 8b", Int(c_ulong(C32 + 1)) == C32 + 1):
        fails += 1
    total += 1
    if not check("conv intptr 64b", Int(c_intptr_t(WIDE)) == WIDE):
        fails += 1
    total += 1
    if not check("conv uintptr 64b", Int(c_uintptr_t(WIDE)) == WIDE):
        fails += 1

    # 4. aliases in function signatures (plain def, grammar only)
    total += 1
    if not check("type-in-def-signature", Int(c_abi_signature(2, 3)) == 5):
        fails += 1
    var passed = total - fails
    print("RESULT: " + String(passed) + "/" + String(total) + " PASSED")
    if fails != 0:
        print("RESULT: " + String(fails) + " FAILED")
        raise Error("conformance FAILED (issue #25): " + String(fails) + " checks FAIL")
