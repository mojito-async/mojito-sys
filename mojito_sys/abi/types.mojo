# mojito-sys S1.2 — ABI C-type aliases (issue #25)
#
# Spec §7.1: use std.ffi aliases whenever they already satisfy the
# requirement; mojito-sys MAY re-export or normalize names. Do not create a
# redundant type system.
#
# Probe findings (Mojo 1.0.0b2, Darwin arm64):
#   - std.ffi exports lowercase `comptime` C-type aliases: c_char, c_short,
#     c_int, c_long, c_long_long, c_uchar, c_ushort, c_uint, c_ulong,
#     c_ulong_long, c_size_t, c_ssize_t, c_float, c_double, c_pid_t. The
#     conventional uppercase aliases (CChar, CInt, SChar...) do NOT exist
#     in this toolchain; only the lowercase comptime surface is provided.
#   - `alias X = ...` is deprecated in b2; `comptime X = ...` is the
#     supported spelling for named type bindings. b2 rejects a comptime
#     binding that shadows an imported name, so each std.ffi alias is
#     imported under a private `_ffi_*` name and re-exported below.
#   - Mojo b2 has no sizeof()/bitwidth builtin, and Int/UInt/Bool expose no
#     `.dtype`. Scalar type widths are derived from the compiler-resolved
#     runtime `dtype` of each type value (see _size_in_bytes); the
#     1/2/4/8-byte mapping is static per DType.
#   - LP64 width table this module conforms to (verified by
#     tests/s1/abi/types/conformance.mojo):
#       char 1, short 2, int 4, long 8, long long 8, size_t/ssize_t 8,
#       pid_t 4, socklen_t 4, float 4, double 8, _Bool 1.
#
# Identity map (review PR #34, M2): every `c_*` name below resolves to a
# real Mojo scalar with the C width:
#   c_char=Int8 (signed char on this toolchain, documented assumption),
#   c_short=Int16, c_int=Int32, c_long=Int64 (LP64), c_long_long=Int64,
#   c_uchar=UInt8, c_ushort=UInt16, c_uint=UInt32, c_ulong=UInt64,
#   c_ulong_long=UInt64, c_size_t=UInt, c_ssize_t=Int (pointer-sized),
#   c_float=Float32, c_double=Float64, c_pid_t=Int32 (pid_t is
#   platform-defined but 32-bit signed on the supported targets),
#   c_socklen_t=UInt32 (spec §7.1 L630), c_bool=Bool, c_intptr_t=Int,
#   c_uintptr_t=UInt.

from std.ffi import c_char as _ffi_c_char
from std.ffi import c_double as _ffi_c_double
from std.ffi import c_float as _ffi_c_float
from std.ffi import c_int as _ffi_c_int
from std.ffi import c_long as _ffi_c_long
from std.ffi import c_long_long as _ffi_c_long_long
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
# source of truth for each binding; these comptime names give the normalized
# `c_*` spelling a fixed home.
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

# c_pid_t: bound to the 32-bit signed C pid_t (Darwin/Linux). The std.ffi
# c_pid_t maps to 64-bit Int on this toolchain — do not re-export that
# binding; the supported-target pid_t is a signed 32-bit int.
comptime c_pid_t = Int32

# c_socklen_t: S1.14 decision (issue #47), PATH A — add now rather than
# defer to S6. Spec §7.1 L630 says socket-length values MAY be normalized;
# socklen_t is a 32-bit unsigned int on every supported target
# (__darwin_socklen_t = __uint32_t on Darwin arm64/i386 per
# sys/_types.h; uint32_t on Linux LP64), so binding it here gives the S6
# socket lanes (#74) the correct vocabulary at trivial cost.
comptime c_socklen_t = UInt32

# Additional normalized names from spec §7.1's wish list, bound to Mojo
# builtins directly (the std.ffi surface above is the only C-type coverage
# the toolchain provides). LP64 widths.
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

# C `_Bool` — 1 byte on LP64. b2 exposes no Bool dtype; the 1-byte fact is
# asserted in conformance via the documented comptime constant.
comptime c_bool = Bool

# ---------------------------------------------------------------------------
# CTypeSizes — width oracle for the aliases above.
#
# TEST ORACLE ONLY (review PR #34, M8): consumed by
# tests/s1/abi/types/conformance.mojo to assert the LP64 width table. Not a
# production buffer-sizing API; keep it off hot paths.
#
# Reads the runtime `dtype` of the ALIAS NAME itself (not the underlying
# builtin), so a mis-bound alias fails conformance (review H1). -1 is
# returned for any DType outside the table (fail-closed, review M4).
struct CTypeSizes:

    @staticmethod
    def int8() -> Int:
        return _size_in_bytes(c_int8.dtype)

    @staticmethod
    def uint8() -> Int:
        return _size_in_bytes(c_uint8.dtype)

    @staticmethod
    def int16() -> Int:
        return _size_in_bytes(c_int16.dtype)

    @staticmethod
    def uint16() -> Int:
        return _size_in_bytes(c_uint16.dtype)

    @staticmethod
    def int32() -> Int:
        return _size_in_bytes(c_int32.dtype)

    @staticmethod
    def uint32() -> Int:
        return _size_in_bytes(c_uint32.dtype)

    @staticmethod
    def int64() -> Int:
        return _size_in_bytes(c_int64.dtype)

    @staticmethod
    def uint64() -> Int:
        return _size_in_bytes(c_uint64.dtype)

    @staticmethod
    def float32() -> Int:
        return _size_in_bytes(c_float.dtype)

    @staticmethod
    def float64() -> Int:
        return _size_in_bytes(c_double.dtype)

    @staticmethod
    def size_t() -> Int:
        return _size_in_bytes(c_size_t.dtype)

    @staticmethod
    def long() -> Int:
        return _size_in_bytes(c_long.dtype)

    @staticmethod
    def ulong() -> Int:
        return _size_in_bytes(c_ulong.dtype)

    @staticmethod
    def pid_t() -> Int:
        return _size_in_bytes(c_pid_t.dtype)

    @staticmethod
    def socklen() -> Int:
        return _size_in_bytes(c_socklen_t.dtype)

    @staticmethod
    def bool() -> Int:
        # Bool/_Bool has no .dtype in b2; documented comptime fact (LP64).
        return 1


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
        return -1  # fail-closed for any dtype outside the LP64 table
