# mojito-sys S1.2 — ABI C-type aliases (issue #25)
#
# Spec §7.1: use std.ffi aliases whenever they already satisfy the
# requirement; mojito-sys MAY re-export or normalize names. Do not create a
# redundant type system.
#
# Probe findings (Mojo 1.0.0b2, Darwin arm64, LP64):
#   - std.ffi exports lowercase `comptime` C-type aliases: c_char, c_short,
#     c_int, c_long, c_long_long, c_uchar, c_ushort, c_uint, c_ulong,
#     c_ulong_long, c_size_t, c_ssize_t, c_float, c_double, c_pid_t. The
#     conventional uppercase aliases (CChar, CInt, SChar...) do NOT exist in
#     this toolchain; only the lowercase comptime surface is provided.
#   - `alias X = ...` is deprecated in b2; `comptime X = ...` is the
#     supported spelling for named type bindings. b2 rejects a comptime
#     binding that shadows an imported name, so each std.ffi alias is
#     imported under a private `_ffi_*` name and rebound to the public
#     `c_*` comptime name.
#   - Mojo b2 has no sizeof()/bitwidth builtin. Scalar type widths are
#     derived from the compiler-resolved runtime `dtype` of each type value
#     (see _size_in_bytes); the 1/2/4/8-byte mapping is static per DType.
#     `c_size_t` resolves to Mojo `UInt` (dtype `uint`); `c_ssize_t` and
#     `c_pid_t` are bound to Mojo `Int`, which exposes no `.dtype` in b2 —
#     their widths are asserted in conformance.mojo via conversion
#     semantics instead.
#   - LP64 C width facts: char 1, short 2, int 4, long 8, long long 8,
#     size_t/ssize_t 8, float 4, double 8.

from std.ffi import c_char as _ffi_c_char
from std.ffi import c_double as _ffi_c_double
from std.ffi import c_float as _ffi_c_float
from std.ffi import c_int as _ffi_c_int
from std.ffi import c_long as _ffi_c_long
from std.ffi import c_long_long as _ffi_c_long_long
from std.ffi import c_pid_t as _ffi_c_pid_t
from std.ffi import c_short as _ffi_c_short
from std.ffi import c_size_t as _ffi_c_size_t
from std.ffi import c_ssize_t as _ffi_c_ssize_t
from std.ffi import c_uchar as _ffi_c_uchar
from std.ffi import c_uint as _ffi_c_uint
from std.ffi import c_ulong as _ffi_c_ulong
from std.ffi import c_ulong_long as _ffi_c_ulong_long
from std.ffi import c_ushort as _ffi_c_ushort

# Re-export the std.ffi aliases under the mojito_sys.abi.types namespace so
# consumers have one stable import surface for C types. std.ffi remains the
# source of truth for each binding; these comptime names simply give the
# normalized `c_*` spelling a fixed home.
comptime c_char = _ffi_c_char
comptime c_uchar = _ffi_c_uchar
comptime c_short = _ffi_c_short
comptime c_ushort = _ffi_c_ushort
comptime c_int = _ffi_c_int
comptime c_uint = _ffi_c_uint
comptime c_long = _ffi_c_long
comptime c_ulong = _ffi_c_ulong
comptime c_long_long = _ffi_c_long_long
comptime c_ulong_long = _ffi_c_ulong_long
comptime c_size_t = _ffi_c_size_t
comptime c_ssize_t = _ffi_c_ssize_t
comptime c_float = _ffi_c_float
comptime c_double = _ffi_c_double
comptime c_pid_t = _ffi_c_pid_t

# Additional normalized names from spec §7.1's wish list that map to Mojo
# builtins directly (no std.ffi alias exists for them). LP64 bindings.
comptime c_int8 = Int8
comptime c_uint8 = UInt8
comptime c_int16 = Int16
comptime c_uint16 = UInt16
comptime c_int32 = Int32
comptime c_uint32 = UInt32
comptime c_int64 = Int64
comptime c_uint64 = UInt64
comptime c_intptr_t = Int
comptime c_uintptr_t = UInt

# C `bool`/`_Bool` — 1 byte on LP64. Width conformance is asserted in
# conformance.mojo.
comptime c_bool = Bool

# ---------------------------------------------------------------------------
# CTypeSizes — pure-Mojo width verifier used by tests.
#
# Returns the size in bytes of each normalized C type by consulting the
# compiler-resolved runtime `dtype` of the alias. No FFI call, no
# allocation. Useful for conformance asserts and for code that must size a
# native buffer without importing the VM layer.
struct CTypeSizes:

    @staticmethod
    def int8() -> Int:
        return _size_in_bytes(Int8.dtype)

    @staticmethod
    def uint8() -> Int:
        return _size_in_bytes(UInt8.dtype)

    @staticmethod
    def int16() -> Int:
        return _size_in_bytes(Int16.dtype)

    @staticmethod
    def uint16() -> Int:
        return _size_in_bytes(UInt16.dtype)

    @staticmethod
    def int32() -> Int:
        return _size_in_bytes(Int32.dtype)

    @staticmethod
    def uint32() -> Int:
        return _size_in_bytes(UInt32.dtype)

    @staticmethod
    def int64() -> Int:
        return _size_in_bytes(Int64.dtype)

    @staticmethod
    def uint64() -> Int:
        return _size_in_bytes(UInt64.dtype)

    @staticmethod
    def float32() -> Int:
        return _size_in_bytes(Float32.dtype)

    @staticmethod
    def float64() -> Int:
        return _size_in_bytes(Float64.dtype)

    @staticmethod
    def size_t() -> Int:
        return _size_in_bytes(c_size_t.dtype)

    @staticmethod
    def long() -> Int:
        return _size_in_bytes(c_long.dtype)

    @staticmethod
    def ulong() -> Int:
        return _size_in_bytes(c_ulong.dtype)


def _size_in_bytes(dt: DType) -> Int:
    if dt == DType.int8 or dt == DType.uint8:
        return 1
    elif dt == DType.int16 or dt == DType.uint16:
        return 2
    elif dt == DType.int32 or dt == DType.uint32 or dt == DType.float32:
        return 4
    elif (
        dt == DType.int64
        or dt == DType.uint64
        or dt == DType.float64
        or dt == DType.uint
    ):
        return 8
    else:
        return 0