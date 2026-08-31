# spike/abi/types.mojo — M1.2 (#124) struct-layout half: Mojo declarations
# of the OS-struct inventory from #122, declared DIRECTLY (no C wrapper in
# between — that is the whole point of this leg).
#
# FINDING (documented here, verified by struct_layout_test.mojo against
# spike/abi/oracle.c): Mojo 1.0.0b2 lays out a plain struct exactly like a
# C compiler does for POD aggregates — fields in declaration order, each
# at its natural alignment, trailing padding added so the struct's own
# size is a multiple of its own alignment (verified directly: a struct of
# {Int64, Int32} sizes to 16 with the Int32 at offset 8, and a struct of
# {UInt8, UInt64} sizes to 16 with the UInt64 at offset 8 — both match C
# exactly). Mojo b2 has NO sizeof()/alignof() builtin (probed directly:
# `sizeof[T]()` is "unknown declaration"); every size/offset in this spike
# is therefore measured the same way mojito_sys/abi/types.mojo's own
# CTypeSizes oracle would, but via POINTER ARITHMETIC instead of a dtype
# table, since these are aggregates, not scalars:
#   size:   Int(stack_allocation[2, T]() + 1) - Int(stack_allocation[2, T]())
#   offset: Int(UnsafePointer(to=instance.field)) - Int(UnsafePointer(to=instance))
#
# TRAP FOUND AND FIXED HERE (real, dynamically caught by the tests below,
# not theorized): a fixed-size byte array field MUST be `InlineArray[UInt8,
# N]`, never `SIMD[DType.uint8, N]`. A `SIMD[DType.uint8, 16]` field
# embedded in a struct carries hardware VECTOR alignment (16 bytes) in
# Mojo, not the 1-byte alignment a C `unsigned char[16]` array has —
# confirmed directly: a synthetic struct with a SIMD[DType.uint8, 16]
# field at byte offset 8 came out at offset 16 (8 bytes of silent padding
# Mojo inserted and C never would), and the struct's own overall alignment
# jumped to 16, inflating its total size. This is exactly the "silent
# padding difference" issue #124 warns shows up as a mysterious EINVAL
# later — filed as mojito-sys#194. It was caught here ONLY because
# struct_layout_test.mojo diffs
# against a live C oracle rather than trusting the Mojo declaration on
# its own. `SockaddrIn6*.sin6_addr` and `Sockaddr{In,In6,Un}*`'s byte
# arrays are `InlineArray[UInt8, N]` for exactly this reason; a smaller
# SIMD[DType.uint8, 8] (sin_zero) happened to pass by COINCIDENCE in an
# earlier draft (its offset was already a multiple of 8), which is worse,
# not better — it would have shipped a latent bug for any struct whose
# preceding fields summed to a non-multiple of the vector's alignment.
#
# ONE STRUCT MOJO CANNOT EXPRESS EXACTLY (recorded per issue #124's "any
# struct Mojo cannot express is written up with what it would need"):
# Apple's <sys/event.h> wraps `struct kevent` in `#pragma pack(4)`, which
# forces the C struct's own alignment to 4 despite every member being
# naturally 8-byte aligned (ident/data/udata are uintptr_t/intptr_t/void*).
# Mojo 1.0.0b2 has no packing/alignment-override attribute (probed
# directly: `@packed` is "unknown declaration", and no alternative is
# documented in the Modular guidance bundled with this repo's Mojo skill).
# The Kevent struct below therefore has Mojo-computed alignment 8, not the
# real ABI's 4. This is a genuine declaration gap, not skipped: size (32)
# and every field offset still match exactly (verified below) because the
# struct's own tail field ends at offset 32, already a multiple of 8, so
# the alignment difference has NO observable effect on this struct's own
# layout or its stride inside an array. It would matter for a future
# struct whose tail ended on a 4-but-not-8 byte boundary; kevent is not
# that struct. What full fidelity would need: a Mojo struct-alignment
# override attribute — filed as mojito-sys#198 as a feature-gap write-up,
# not a crash issue, since nothing crashes here.

from std.sys import CompilationTarget

comptime _is_macos = CompilationTarget().is_macos()
comptime _is_linux = CompilationTarget().is_linux()

# ---------------------------------------------------------------------------
# struct timespec — <time.h>. Same on both supported targets: two Int64
# fields, no platform divergence (verified: LP64 tv_sec/tv_nsec are both
# `long` on macOS and Linux).
# ---------------------------------------------------------------------------
struct Timespec:
    var tv_sec: Int64
    var tv_nsec: Int64

    def __init__(out self, tv_sec: Int64, tv_nsec: Int64):
        self.tv_sec = tv_sec
        self.tv_nsec = tv_nsec


# ---------------------------------------------------------------------------
# struct timeval — <sys/time.h>. tv_usec's WIDTH is the platform-divergent
# fact (oracle_fieldsizeof_timeval_tv_usec in oracle.c measures it): 4
# bytes (suseconds_t = __int32_t) on Darwin, 8 bytes on Linux/glibc
# (suseconds_t is `long`). Two declarations, selected by comptime.
# ---------------------------------------------------------------------------
struct TimevalDarwin:
    var tv_sec: Int64
    var tv_usec: Int32

    def __init__(out self, tv_sec: Int64, tv_usec: Int32):
        self.tv_sec = tv_sec
        self.tv_usec = tv_usec


struct TimevalLinux:
    var tv_sec: Int64
    var tv_usec: Int64

    def __init__(out self, tv_sec: Int64, tv_usec: Int64):
        self.tv_sec = tv_sec
        self.tv_usec = tv_usec


# ---------------------------------------------------------------------------
# sa_family_t / socklen_t scalars (<sys/socket.h>). Darwin: sa_family_t is
# 1 byte (__uint8_t). Linux/glibc: sa_family_t is 2 bytes (unsigned short).
# socklen_t is a 4-byte uint32 on both.
# ---------------------------------------------------------------------------
comptime SaFamilyDarwin = UInt8
comptime SaFamilyLinux = UInt16
comptime SockLen = UInt32

# ---------------------------------------------------------------------------
# struct sockaddr_in — <netinet/in.h>. Darwin carries sin_len (1 byte)
# ahead of a 1-byte sin_family; Linux has no sin_len and sin_family is a
# plain 2-byte sa_family_t.
# ---------------------------------------------------------------------------
struct SockaddrInDarwin:
    var sin_len: UInt8
    var sin_family: UInt8
    var sin_port: UInt16
    var sin_addr: UInt32
    var sin_zero: InlineArray[UInt8, 8]

    def __init__(
        out self,
        sin_len: UInt8,
        sin_family: UInt8,
        sin_port: UInt16,
        sin_addr: UInt32,
    ):
        self.sin_len = sin_len
        self.sin_family = sin_family
        self.sin_port = sin_port
        self.sin_addr = sin_addr
        self.sin_zero = InlineArray[UInt8, 8](fill=0)


struct SockaddrInLinux:
    var sin_family: UInt16
    var sin_port: UInt16
    var sin_addr: UInt32
    var sin_zero: InlineArray[UInt8, 8]

    def __init__(
        out self, sin_family: UInt16, sin_port: UInt16, sin_addr: UInt32
    ):
        self.sin_family = sin_family
        self.sin_port = sin_port
        self.sin_addr = sin_addr
        self.sin_zero = InlineArray[UInt8, 8](fill=0)


# ---------------------------------------------------------------------------
# struct sockaddr_in6 — <netinet/in.h>. Same len/family divergence as v4.
# sin6_addr travels as a 16-byte SIMD lane rather than a nested struct
# (Mojo has no anonymous-union/nested in6_addr type here; the byte layout
# is what the ABI actually cares about).
# ---------------------------------------------------------------------------
struct SockaddrIn6Darwin:
    var sin6_len: UInt8
    var sin6_family: UInt8
    var sin6_port: UInt16
    var sin6_flowinfo: UInt32
    var sin6_addr: InlineArray[UInt8, 16]
    var sin6_scope_id: UInt32

    def __init__(
        out self,
        sin6_len: UInt8,
        sin6_family: UInt8,
        sin6_port: UInt16,
        sin6_flowinfo: UInt32,
        sin6_addr: InlineArray[UInt8, 16],
        sin6_scope_id: UInt32,
    ):
        self.sin6_len = sin6_len
        self.sin6_family = sin6_family
        self.sin6_port = sin6_port
        self.sin6_flowinfo = sin6_flowinfo
        self.sin6_addr = sin6_addr
        self.sin6_scope_id = sin6_scope_id


struct SockaddrIn6Linux:
    var sin6_family: UInt16
    var sin6_port: UInt16
    var sin6_flowinfo: UInt32
    var sin6_addr: InlineArray[UInt8, 16]
    var sin6_scope_id: UInt32

    def __init__(
        out self,
        sin6_family: UInt16,
        sin6_port: UInt16,
        sin6_flowinfo: UInt32,
        sin6_addr: InlineArray[UInt8, 16],
        sin6_scope_id: UInt32,
    ):
        self.sin6_family = sin6_family
        self.sin6_port = sin6_port
        self.sin6_flowinfo = sin6_flowinfo
        self.sin6_addr = sin6_addr
        self.sin6_scope_id = sin6_scope_id


# ---------------------------------------------------------------------------
# struct sockaddr_un — <sys/un.h>. sun_path capacity is 104 on Darwin, 108
# on Linux (measured by oracle_sun_path_capacity(), not assumed). Declared
# as a fixed-size byte array per platform; Mojo has no const-generic
# array-length parameter tied to a comptime branch cleanly at this
# toolchain version, so two full struct declarations again.
# ---------------------------------------------------------------------------
comptime SUN_PATH_CAP_DARWIN = 104
comptime SUN_PATH_CAP_LINUX = 108


struct SockaddrUnDarwin:
    var sun_len: UInt8
    var sun_family: UInt8
    var sun_path: InlineArray[UInt8, SUN_PATH_CAP_DARWIN]

    def __init__(out self, sun_len: UInt8, sun_family: UInt8):
        self.sun_len = sun_len
        self.sun_family = sun_family
        self.sun_path = InlineArray[UInt8, SUN_PATH_CAP_DARWIN](fill=0)


struct SockaddrUnLinux:
    var sun_family: UInt16
    var sun_path: InlineArray[UInt8, SUN_PATH_CAP_LINUX]

    def __init__(out self, sun_family: UInt16):
        self.sun_family = sun_family
        self.sun_path = InlineArray[UInt8, SUN_PATH_CAP_LINUX](fill=0)


# ---------------------------------------------------------------------------
# struct iovec — <sys/uio.h>. Same on both targets: void* + size_t.
# ---------------------------------------------------------------------------
struct Iovec:
    var iov_base: Int  # void* transported as a machine word (repo convention)
    var iov_len: UInt64

    def __init__(out self, iov_base: Int, iov_len: UInt64):
        self.iov_base = iov_base
        self.iov_len = iov_len


# ---------------------------------------------------------------------------
# struct kevent — <sys/event.h>, BSD/macOS only. See the file-header note:
# the real ABI is #pragma pack(4)'d (alignment 4); this declaration's
# Mojo-computed alignment is 8. Size and every field offset match exactly.
# ---------------------------------------------------------------------------
struct Kevent:
    var ident: UInt64
    var filter: Int16
    var flags: UInt16
    var fflags: UInt32
    var data: Int64
    var udata: UInt64  # void* as a machine word

    def __init__(
        out self,
        ident: UInt64,
        filter: Int16,
        flags: UInt16,
        fflags: UInt32,
        data: Int64,
        udata: UInt64,
    ):
        self.ident = ident
        self.filter = filter
        self.flags = flags
        self.fflags = fflags
        self.data = data
        self.udata = udata


# ---------------------------------------------------------------------------
# struct epoll_event — <sys/epoll.h>, Linux only. UNVERIFIED ON THIS HOST
# (macOS has no epoll header at all) — struct_layout_test.mojo reports this
# lane ENVIRONMENT/SKIP on macOS and relies on the suite-linux CI job for a
# real measurement. glibc packs this struct with __attribute__((packed))
# on x86-64 (events:4 + data:8 = 12 bytes, no padding) and leaves it
# naturally aligned on AArch64 (events:4 + pad:4 + data:8 = 16 bytes) —
# issue #124's own callout. Declared here as the UNPACKED (natural, 16-byte)
# shape; the packed x86-64 shape needs an explicit sub-natural alignment
# override the same way Kevent's pragma-pack gap does (no Mojo attribute
# for it as of b2) — see EpollEventPacked note in struct_layout_test.mojo.
# ---------------------------------------------------------------------------
struct EpollEventNatural:
    var events: UInt32
    var data_u64: UInt64

    def __init__(out self, events: UInt32, data_u64: UInt64):
        self.events = events
        self.data_u64 = data_u64
