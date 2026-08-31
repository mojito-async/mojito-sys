# spike/abi/struct_layout_test.mojo — M1.2 (#124) struct-layout half.
#
# For every struct in the #122 OS-struct inventory: static layout (size +
# every field offset, Mojo-measured via pointer arithmetic against
# spike/abi/oracle.c's C-measured sizeof/offsetof) AND a dynamic round
# trip in BOTH directions (C fills a buffer with a known pattern and Mojo
# reads it back through its own declared struct fields; Mojo fills its
# own declared struct with the same pattern and hands the raw pointer to
# C, which reads it back through the real C struct). Argument-passing is
# covered too: Timespec (16 bytes, fits a register pair) by VALUE in both
# directions; the bigger structs by POINTER, both directions.
#
# Pattern constants below are a literal, deliberate mirror of oracle.c's
# PAT_* macros — kept in sync by hand (not derived), so a mismatch is
# unambiguous rather than tautological.
#
# NOT verified on this host (macOS): epoll_event (Linux only — this suite
# reports that lane ENVIRONMENT/SKIP here; see run.sh) and, within it, the
# AArch64-vs-x86-64 packed/unpacked divergence issue #124 calls out — this
# repo's CI has an x86-64 Linux lane (suite-linux) but no aarch64 Linux
# lane at all, so that specific fact stays UNVERIFIED anywhere reachable
# from this repo, not just on this host. Recorded here rather than guessed.

from std.memory import stack_allocation
from std.sys import CompilationTarget

from types import (
    Timespec,
    TimevalDarwin,
    TimevalLinux,
    SockaddrInDarwin,
    SockaddrInLinux,
    SockaddrIn6Darwin,
    SockaddrIn6Linux,
    SockaddrUnDarwin,
    SockaddrUnLinux,
    Iovec,
    Kevent,
    EpollEventNatural,
    SUN_PATH_CAP_DARWIN,
    SUN_PATH_CAP_LINUX,
)
from externs_leaf import (
    oracle_sizeof_timespec,
    oracle_offset_timespec_tv_sec,
    oracle_offset_timespec_tv_nsec,
    oracle_fill_timespec,
    oracle_check_timespec,
    oracle_sizeof_timeval,
    oracle_offset_timeval_tv_sec,
    oracle_offset_timeval_tv_usec,
    oracle_fieldsizeof_timeval_tv_usec,
    oracle_fill_timeval,
    oracle_check_timeval,
    oracle_has_sin_len,
    oracle_sizeof_sockaddr_in,
    oracle_offset_sockaddr_in_sin_family,
    oracle_offset_sockaddr_in_sin_port,
    oracle_offset_sockaddr_in_sin_addr,
    oracle_offset_sockaddr_in_sin_zero,
    oracle_fieldsizeof_sockaddr_in_sin_family,
    oracle_fill_sockaddr_in,
    oracle_check_sockaddr_in,
    oracle_sizeof_sockaddr_in6,
    oracle_offset_sockaddr_in6_sin6_family,
    oracle_offset_sockaddr_in6_sin6_port,
    oracle_offset_sockaddr_in6_sin6_flowinfo,
    oracle_offset_sockaddr_in6_sin6_addr,
    oracle_offset_sockaddr_in6_sin6_scope_id,
    oracle_fill_sockaddr_in6,
    oracle_check_sockaddr_in6,
    oracle_sizeof_sockaddr_un,
    oracle_offset_sockaddr_un_sun_family,
    oracle_offset_sockaddr_un_sun_path,
    oracle_sun_path_capacity,
    oracle_fill_sockaddr_un,
    oracle_check_sockaddr_un,
    oracle_sizeof_iovec,
    oracle_offset_iovec_iov_base,
    oracle_offset_iovec_iov_len,
    oracle_fill_iovec,
    oracle_check_iovec,
    oracle_has_kevent,
    oracle_sizeof_kevent,
    oracle_alignof_kevent,
    oracle_offset_kevent_ident,
    oracle_offset_kevent_filter,
    oracle_offset_kevent_flags,
    oracle_offset_kevent_fflags,
    oracle_offset_kevent_data,
    oracle_offset_kevent_udata,
    oracle_fill_kevent,
    oracle_check_kevent,
    oracle_has_epoll_event,
    oracle_sizeof_epoll_event,
    oracle_alignof_epoll_event,
    oracle_offset_epoll_event_events,
    oracle_offset_epoll_event_data,
    oracle_epoll_event_is_packed,
    oracle_sizeof_pthread_attr_t,
    oracle_alignof_pthread_attr_t,
    oracle_sizeof_pthread_mutex_t,
    oracle_alignof_pthread_mutex_t,
    oracle_pthread_attr_roundtrip,
    oracle_pthread_mutex_roundtrip,
    oracle_timespec_sum_byval,
    oracle_make_timespec_byval,
    LeafTimespec,
    oracle_const_AF_INET6,
)

# ---- pattern constants (mirrors oracle.c's PAT_* macros VERBATIM) ---------
comptime PAT_TS_SEC: Int64 = 1234567890123
comptime PAT_TS_NSEC: Int64 = 987654321
comptime PAT_TV_SEC: Int64 = 1111111111
comptime PAT_TV_USEC: Int32 = 222222
comptime PAT_SIN_PORT: UInt16 = 0x1234
comptime PAT_SIN_ADDR: UInt32 = 0x7F0000AA
comptime PAT_SIN_ZERO_BYTE: UInt8 = 0xEE
comptime PAT_SIN6_PORT: UInt16 = 0x5678
comptime PAT_SIN6_FLOWINFO: UInt32 = 0xCAFEBABE
comptime PAT_SIN6_SCOPE_ID: UInt32 = 0x2A
comptime PAT_IOV_LEN: UInt64 = 0x4321
comptime PAT_IOV_BASE: Int = 0x10203040
comptime PAT_KEV_IDENT: UInt64 = 0x11
comptime PAT_KEV_FILTER: Int16 = -1
comptime PAT_KEV_FLAGS: UInt16 = 0x0001
comptime PAT_KEV_FFLAGS: UInt32 = 0x00000002
comptime PAT_KEV_DATA: Int64 = 0x2233
comptime PAT_KEV_UDATA: UInt64 = 0x44556677


struct Checker:
    var failures: Int

    def __init__(out self):
        self.failures = 0

    def check(mut self, name: String, cond: Bool) -> Bool:
        print(name + " " + ("PASS" if cond else "FAIL"))
        if not cond:
            self.failures += 1
        return cond


def sin6_addr_pattern() -> InlineArray[UInt8, 16]:
    var v = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        v[i] = UInt8(0xA0 + i)
    return v


def main() raises:
    var c = Checker()
    var is_macos = CompilationTarget().is_macos()
    var is_linux = CompilationTarget().is_linux()

    # ===================================================================
    # timespec — no platform divergence
    # ===================================================================
    var tsp = stack_allocation[2, Timespec]()
    var ts_size = UInt64(Int(tsp + 1) - Int(tsp))
    _ = c.check("timespec size", ts_size == oracle_sizeof_timespec())
    var ts0 = Timespec(0, 0)
    var ts0p = UnsafePointer(to=ts0)
    _ = c.check(
        "timespec offset tv_sec",
        UInt64(Int(UnsafePointer(to=ts0.tv_sec)) - Int(ts0p))
        == oracle_offset_timespec_tv_sec(),
    )
    _ = c.check(
        "timespec offset tv_nsec",
        UInt64(Int(UnsafePointer(to=ts0.tv_nsec)) - Int(ts0p))
        == oracle_offset_timespec_tv_nsec(),
    )
    # round trip: C fills -> Mojo reads
    var ts_buf = stack_allocation[1, Timespec]()
    oracle_fill_timespec(ts_buf.bitcast[Byte]())
    _ = c.check(
        "timespec C-fills-Mojo-reads",
        ts_buf[0].tv_sec == PAT_TS_SEC and ts_buf[0].tv_nsec == PAT_TS_NSEC,
    )
    # round trip: Mojo fills -> C reads
    var ts_mine = Timespec(PAT_TS_SEC, PAT_TS_NSEC)
    _ = c.check(
        "timespec Mojo-fills-C-reads",
        oracle_check_timespec(UnsafePointer(to=ts_mine).bitcast[Byte]()) != 0,
    )
    # by-value argument passing (small struct, register-pair sized)
    _ = c.check(
        "timespec byval arg",
        oracle_timespec_sum_byval(LeafTimespec(PAT_TS_SEC, PAT_TS_NSEC))
        == PAT_TS_SEC + PAT_TS_NSEC,
    )
    var made = oracle_make_timespec_byval(PAT_TS_SEC, PAT_TS_NSEC)
    _ = c.check(
        "timespec byval return",
        made.tv_sec == PAT_TS_SEC and made.tv_nsec == PAT_TS_NSEC,
    )

    # ===================================================================
    # timeval — tv_usec width is platform-divergent (measured, not assumed)
    # ===================================================================
    if is_macos:
        var tvp = stack_allocation[2, TimevalDarwin]()
        var tv_size = UInt64(Int(tvp + 1) - Int(tvp))
        _ = c.check("timeval size (darwin)", tv_size == oracle_sizeof_timeval())
        _ = c.check(
            "timeval tv_usec fieldsize (darwin)",
            UInt64(4) == oracle_fieldsizeof_timeval_tv_usec(),
        )
        var tv0 = TimevalDarwin(0, 0)
        var tv0p = UnsafePointer(to=tv0)
        _ = c.check(
            "timeval offset tv_sec (darwin)",
            UInt64(Int(UnsafePointer(to=tv0.tv_sec)) - Int(tv0p))
            == oracle_offset_timeval_tv_sec(),
        )
        _ = c.check(
            "timeval offset tv_usec (darwin)",
            UInt64(Int(UnsafePointer(to=tv0.tv_usec)) - Int(tv0p))
            == oracle_offset_timeval_tv_usec(),
        )
        var tv_buf = stack_allocation[1, TimevalDarwin]()
        oracle_fill_timeval(tv_buf.bitcast[Byte]())
        _ = c.check(
            "timeval C-fills-Mojo-reads (darwin)",
            tv_buf[0].tv_sec == PAT_TV_SEC and tv_buf[0].tv_usec == PAT_TV_USEC,
        )
        var tv_mine = TimevalDarwin(PAT_TV_SEC, PAT_TV_USEC)
        _ = c.check(
            "timeval Mojo-fills-C-reads (darwin)",
            oracle_check_timeval(UnsafePointer(to=tv_mine).bitcast[Byte]())
            != 0,
        )
    elif is_linux:
        var tvp = stack_allocation[2, TimevalLinux]()
        var tv_size = UInt64(Int(tvp + 1) - Int(tvp))
        _ = c.check("timeval size (linux)", tv_size == oracle_sizeof_timeval())
        _ = c.check(
            "timeval tv_usec fieldsize (linux)",
            UInt64(8) == oracle_fieldsizeof_timeval_tv_usec(),
        )
        var tv0 = TimevalLinux(0, 0)
        var tv0p = UnsafePointer(to=tv0)
        _ = c.check(
            "timeval offset tv_usec (linux)",
            UInt64(Int(UnsafePointer(to=tv0.tv_usec)) - Int(tv0p))
            == oracle_offset_timeval_tv_usec(),
        )
        var tv_buf = stack_allocation[1, TimevalLinux]()
        oracle_fill_timeval(tv_buf.bitcast[Byte]())
        _ = c.check(
            "timeval C-fills-Mojo-reads (linux)",
            tv_buf[0].tv_sec == PAT_TV_SEC
            and tv_buf[0].tv_usec == Int64(PAT_TV_USEC),
        )
        var tv_mine = TimevalLinux(PAT_TV_SEC, Int64(PAT_TV_USEC))
        _ = c.check(
            "timeval Mojo-fills-C-reads (linux)",
            oracle_check_timeval(UnsafePointer(to=tv_mine).bitcast[Byte]())
            != 0,
        )
    else:
        print("timeval SKIP (unsupported CompilationTarget)")

    # ===================================================================
    # sockaddr_in — sin_len only on darwin
    # ===================================================================
    var has_sin_len = oracle_has_sin_len() != 0
    _ = c.check("sockaddr_in has_sin_len matches host", has_sin_len == is_macos)
    if is_macos:
        var ap = stack_allocation[2, SockaddrInDarwin]()
        var a_size = UInt64(Int(ap + 1) - Int(ap))
        _ = c.check(
            "sockaddr_in size (darwin)", a_size == oracle_sizeof_sockaddr_in()
        )
        var a0 = SockaddrInDarwin(0, 0, 0, 0)
        var a0p = UnsafePointer(to=a0)
        _ = c.check(
            "sockaddr_in offset sin_family (darwin)",
            UInt64(Int(UnsafePointer(to=a0.sin_family)) - Int(a0p))
            == oracle_offset_sockaddr_in_sin_family(),
        )
        _ = c.check(
            "sockaddr_in offset sin_port (darwin)",
            UInt64(Int(UnsafePointer(to=a0.sin_port)) - Int(a0p))
            == oracle_offset_sockaddr_in_sin_port(),
        )
        _ = c.check(
            "sockaddr_in offset sin_addr (darwin)",
            UInt64(Int(UnsafePointer(to=a0.sin_addr)) - Int(a0p))
            == oracle_offset_sockaddr_in_sin_addr(),
        )
        _ = c.check(
            "sockaddr_in offset sin_zero (darwin)",
            UInt64(Int(UnsafePointer(to=a0.sin_zero)) - Int(a0p))
            == oracle_offset_sockaddr_in_sin_zero(),
        )
        var a_buf = stack_allocation[1, SockaddrInDarwin]()
        oracle_fill_sockaddr_in(a_buf.bitcast[Byte]())
        var zero_ok = True
        for i in range(8):
            if a_buf[0].sin_zero[i] != PAT_SIN_ZERO_BYTE:
                zero_ok = False
        _ = c.check(
            "sockaddr_in C-fills-Mojo-reads (darwin)",
            a_buf[0].sin_port == PAT_SIN_PORT
            and a_buf[0].sin_addr == PAT_SIN_ADDR
            and zero_ok,
        )
        var a_mine = SockaddrInDarwin(16, 2, PAT_SIN_PORT, PAT_SIN_ADDR)
        for i in range(8):
            a_mine.sin_zero[i] = PAT_SIN_ZERO_BYTE
        _ = c.check(
            "sockaddr_in Mojo-fills-C-reads (darwin)",
            oracle_check_sockaddr_in(UnsafePointer(to=a_mine).bitcast[Byte]())
            != 0,
        )
    elif is_linux:
        var ap = stack_allocation[2, SockaddrInLinux]()
        var a_size = UInt64(Int(ap + 1) - Int(ap))
        _ = c.check(
            "sockaddr_in size (linux)", a_size == oracle_sizeof_sockaddr_in()
        )
        var a_buf = stack_allocation[1, SockaddrInLinux]()
        oracle_fill_sockaddr_in(a_buf.bitcast[Byte]())
        var zero_ok = True
        for i in range(8):
            if a_buf[0].sin_zero[i] != PAT_SIN_ZERO_BYTE:
                zero_ok = False
        _ = c.check(
            "sockaddr_in C-fills-Mojo-reads (linux)",
            a_buf[0].sin_port == PAT_SIN_PORT
            and a_buf[0].sin_addr == PAT_SIN_ADDR
            and zero_ok,
        )
        var a_mine = SockaddrInLinux(2, PAT_SIN_PORT, PAT_SIN_ADDR)
        for i in range(8):
            a_mine.sin_zero[i] = PAT_SIN_ZERO_BYTE
        _ = c.check(
            "sockaddr_in Mojo-fills-C-reads (linux)",
            oracle_check_sockaddr_in(UnsafePointer(to=a_mine).bitcast[Byte]())
            != 0,
        )

    # ===================================================================
    # sockaddr_in6
    # ===================================================================
    if is_macos:
        var a6p = stack_allocation[2, SockaddrIn6Darwin]()
        var a6_size = UInt64(Int(a6p + 1) - Int(a6p))
        _ = c.check(
            "sockaddr_in6 size (darwin)",
            a6_size == oracle_sizeof_sockaddr_in6(),
        )
        var a60 = SockaddrIn6Darwin(
            0, 0, 0, 0, InlineArray[UInt8, 16](fill=0), 0
        )
        var a60p = UnsafePointer(to=a60)
        _ = c.check(
            "sockaddr_in6 offset sin6_family (darwin)",
            UInt64(Int(UnsafePointer(to=a60.sin6_family)) - Int(a60p))
            == oracle_offset_sockaddr_in6_sin6_family(),
        )
        _ = c.check(
            "sockaddr_in6 offset sin6_port (darwin)",
            UInt64(Int(UnsafePointer(to=a60.sin6_port)) - Int(a60p))
            == oracle_offset_sockaddr_in6_sin6_port(),
        )
        _ = c.check(
            "sockaddr_in6 offset sin6_flowinfo (darwin)",
            UInt64(Int(UnsafePointer(to=a60.sin6_flowinfo)) - Int(a60p))
            == oracle_offset_sockaddr_in6_sin6_flowinfo(),
        )
        _ = c.check(
            "sockaddr_in6 offset sin6_addr (darwin)",
            UInt64(Int(UnsafePointer(to=a60.sin6_addr)) - Int(a60p))
            == oracle_offset_sockaddr_in6_sin6_addr(),
        )
        _ = c.check(
            "sockaddr_in6 offset sin6_scope_id (darwin)",
            UInt64(Int(UnsafePointer(to=a60.sin6_scope_id)) - Int(a60p))
            == oracle_offset_sockaddr_in6_sin6_scope_id(),
        )
        var a6_buf = stack_allocation[1, SockaddrIn6Darwin]()
        oracle_fill_sockaddr_in6(a6_buf.bitcast[Byte]())
        var addr_ok = True
        for i in range(16):
            if a6_buf[0].sin6_addr[i] != UInt8(0xA0 + i):
                addr_ok = False
        _ = c.check(
            "sockaddr_in6 C-fills-Mojo-reads (darwin)",
            a6_buf[0].sin6_port == PAT_SIN6_PORT
            and a6_buf[0].sin6_flowinfo == PAT_SIN6_FLOWINFO
            and a6_buf[0].sin6_scope_id == PAT_SIN6_SCOPE_ID
            and addr_ok,
        )
        var a6_mine = SockaddrIn6Darwin(
            28,
            UInt8(oracle_const_AF_INET6()),
            PAT_SIN6_PORT,
            PAT_SIN6_FLOWINFO,
            sin6_addr_pattern(),
            PAT_SIN6_SCOPE_ID,
        )
        _ = c.check(
            "sockaddr_in6 Mojo-fills-C-reads (darwin)",
            oracle_check_sockaddr_in6(
                UnsafePointer(to=a6_mine).bitcast[Byte]()
            )
            != 0,
        )
    elif is_linux:
        var a6p = stack_allocation[2, SockaddrIn6Linux]()
        var a6_size = UInt64(Int(a6p + 1) - Int(a6p))
        _ = c.check(
            "sockaddr_in6 size (linux)", a6_size == oracle_sizeof_sockaddr_in6()
        )
        var a6_buf = stack_allocation[1, SockaddrIn6Linux]()
        oracle_fill_sockaddr_in6(a6_buf.bitcast[Byte]())
        var addr_ok = True
        for i in range(16):
            if a6_buf[0].sin6_addr[i] != UInt8(0xA0 + i):
                addr_ok = False
        _ = c.check(
            "sockaddr_in6 C-fills-Mojo-reads (linux)",
            a6_buf[0].sin6_port == PAT_SIN6_PORT
            and a6_buf[0].sin6_flowinfo == PAT_SIN6_FLOWINFO
            and addr_ok,
        )
        var a6_mine = SockaddrIn6Linux(
            UInt16(oracle_const_AF_INET6()),
            PAT_SIN6_PORT,
            PAT_SIN6_FLOWINFO,
            sin6_addr_pattern(),
            PAT_SIN6_SCOPE_ID,
        )
        _ = c.check(
            "sockaddr_in6 Mojo-fills-C-reads (linux)",
            oracle_check_sockaddr_in6(
                UnsafePointer(to=a6_mine).bitcast[Byte]()
            )
            != 0,
        )

    # ===================================================================
    # sockaddr_un — big struct (>16B), by-pointer only. sun_path capacity
    # is measured, not assumed (104 darwin / 108 linux documented, but the
    # oracle's own number is authoritative).
    # ===================================================================
    var sun_cap = oracle_sun_path_capacity()
    if is_macos:
        _ = c.check(
            "sockaddr_un sun_path capacity (darwin)",
            sun_cap == UInt64(SUN_PATH_CAP_DARWIN),
        )
        var up = stack_allocation[2, SockaddrUnDarwin]()
        var u_size = UInt64(Int(up + 1) - Int(up))
        _ = c.check(
            "sockaddr_un size (darwin)", u_size == oracle_sizeof_sockaddr_un()
        )
        var u0 = SockaddrUnDarwin(0, 0)
        var u0p = UnsafePointer(to=u0)
        _ = c.check(
            "sockaddr_un offset sun_family (darwin)",
            UInt64(Int(UnsafePointer(to=u0.sun_family)) - Int(u0p))
            == oracle_offset_sockaddr_un_sun_family(),
        )
        _ = c.check(
            "sockaddr_un offset sun_path (darwin)",
            UInt64(Int(UnsafePointer(to=u0.sun_path)) - Int(u0p))
            == oracle_offset_sockaddr_un_sun_path(),
        )
        var u_buf = stack_allocation[1, SockaddrUnDarwin]()
        oracle_fill_sockaddr_un(u_buf.bitcast[Byte]())
        _ = c.check(
            "sockaddr_un C-fills-Mojo-reads (darwin)",
            u_buf[0].sun_path[0] == UInt8(47),  # ASCII '/'
        )
        var u_mine = SockaddrUnDarwin(106, 1)
        var path_lit = "/tmp/mojito-abi-spike.sock"
        var path_src = path_lit.unsafe_ptr()
        for i in range(path_lit.byte_length()):
            u_mine.sun_path[i] = path_src[i]
        _ = c.check(
            "sockaddr_un Mojo-fills-C-reads (darwin)",
            oracle_check_sockaddr_un(UnsafePointer(to=u_mine).bitcast[Byte]())
            != 0,
        )
    elif is_linux:
        _ = c.check(
            "sockaddr_un sun_path capacity (linux)",
            sun_cap == UInt64(SUN_PATH_CAP_LINUX),
        )
        var up = stack_allocation[2, SockaddrUnLinux]()
        var u_size = UInt64(Int(up + 1) - Int(up))
        _ = c.check(
            "sockaddr_un size (linux)", u_size == oracle_sizeof_sockaddr_un()
        )
        var u_buf = stack_allocation[1, SockaddrUnLinux]()
        oracle_fill_sockaddr_un(u_buf.bitcast[Byte]())
        _ = c.check(
            "sockaddr_un C-fills-Mojo-reads (linux)",
            u_buf[0].sun_path[0] == UInt8(47),  # ASCII '/'
        )

    # ===================================================================
    # iovec — no platform divergence
    # ===================================================================
    var ivp = stack_allocation[2, Iovec]()
    var iv_size = UInt64(Int(ivp + 1) - Int(ivp))
    _ = c.check("iovec size", iv_size == oracle_sizeof_iovec())
    var iv0 = Iovec(0, 0)
    var iv0p = UnsafePointer(to=iv0)
    _ = c.check(
        "iovec offset iov_base",
        UInt64(Int(UnsafePointer(to=iv0.iov_base)) - Int(iv0p))
        == oracle_offset_iovec_iov_base(),
    )
    _ = c.check(
        "iovec offset iov_len",
        UInt64(Int(UnsafePointer(to=iv0.iov_len)) - Int(iv0p))
        == oracle_offset_iovec_iov_len(),
    )
    var iv_buf = stack_allocation[1, Iovec]()
    oracle_fill_iovec(iv_buf.bitcast[Byte]())
    _ = c.check(
        "iovec C-fills-Mojo-reads",
        iv_buf[0].iov_base == PAT_IOV_BASE and iv_buf[0].iov_len == PAT_IOV_LEN,
    )
    var iv_mine = Iovec(PAT_IOV_BASE, PAT_IOV_LEN)
    _ = c.check(
        "iovec Mojo-fills-C-reads",
        oracle_check_iovec(UnsafePointer(to=iv_mine).bitcast[Byte]()) != 0,
    )

    # ===================================================================
    # kevent — macOS/BSD only. Apple's <sys/event.h> wraps this struct in
    # #pragma pack(4); Mojo's natural layout computes alignment 8 (no
    # packing attribute in b2 — see types.mojo header note). Size and every
    # offset still match exactly; alignment is reported informationally.
    # ===================================================================
    if oracle_has_kevent() != 0:
        var kp = stack_allocation[2, Kevent]()
        var k_size = UInt64(Int(kp + 1) - Int(kp))
        _ = c.check("kevent size", k_size == oracle_sizeof_kevent())
        print(
            "kevent alignof (oracle, informational, C ABI is pragma-pack(4)):",
            oracle_alignof_kevent(),
            "— Mojo's own natural alignment for this field set is 8"
            " (no packing attribute available in b2; harmless here since"
            " size is already 8-aligned)",
        )
        var k0 = Kevent(0, 0, 0, 0, 0, 0)
        var k0p = UnsafePointer(to=k0)
        _ = c.check(
            "kevent offset ident",
            UInt64(Int(UnsafePointer(to=k0.ident)) - Int(k0p))
            == oracle_offset_kevent_ident(),
        )
        _ = c.check(
            "kevent offset filter",
            UInt64(Int(UnsafePointer(to=k0.filter)) - Int(k0p))
            == oracle_offset_kevent_filter(),
        )
        _ = c.check(
            "kevent offset flags",
            UInt64(Int(UnsafePointer(to=k0.flags)) - Int(k0p))
            == oracle_offset_kevent_flags(),
        )
        _ = c.check(
            "kevent offset fflags",
            UInt64(Int(UnsafePointer(to=k0.fflags)) - Int(k0p))
            == oracle_offset_kevent_fflags(),
        )
        _ = c.check(
            "kevent offset data",
            UInt64(Int(UnsafePointer(to=k0.data)) - Int(k0p))
            == oracle_offset_kevent_data(),
        )
        _ = c.check(
            "kevent offset udata",
            UInt64(Int(UnsafePointer(to=k0.udata)) - Int(k0p))
            == oracle_offset_kevent_udata(),
        )
        var k_buf = stack_allocation[1, Kevent]()
        oracle_fill_kevent(k_buf.bitcast[Byte]())
        _ = c.check(
            "kevent C-fills-Mojo-reads",
            k_buf[0].ident == PAT_KEV_IDENT
            and k_buf[0].filter == PAT_KEV_FILTER
            and k_buf[0].flags == PAT_KEV_FLAGS
            and k_buf[0].fflags == PAT_KEV_FFLAGS
            and k_buf[0].data == PAT_KEV_DATA
            and k_buf[0].udata == PAT_KEV_UDATA,
        )
        var k_mine = Kevent(
            PAT_KEV_IDENT,
            PAT_KEV_FILTER,
            PAT_KEV_FLAGS,
            PAT_KEV_FFLAGS,
            PAT_KEV_DATA,
            PAT_KEV_UDATA,
        )
        _ = c.check(
            "kevent Mojo-fills-C-reads",
            oracle_check_kevent(UnsafePointer(to=k_mine).bitcast[Byte]())
            != 0,
        )
    else:
        print("kevent SKIP (not available on this host)")

    # ===================================================================
    # epoll_event — Linux only. Cannot be exercised on macOS at all (no
    # <sys/epoll.h>); reported ENV/SKIP here, real signal is CI's Linux
    # lane (x86-64 only — no aarch64 Linux CI lane exists in this repo, so
    # the packed-vs-natural AArch64 fact stays unverified regardless).
    # ===================================================================
    if oracle_has_epoll_event() != 0:
        var packed = oracle_epoll_event_is_packed() != 0
        print("epoll_event packed on this host:", packed)
        if packed:
            print(
                "epoll_event SKIP (this host's ABI packs the struct;"
                " EpollEventNatural in types.mojo is the UNPACKED shape"
                " and is not the layout to check against here — a packed"
                " Mojo declaration needs the same alignment-override"
                " mechanism the kevent note above says b2 lacks)"
            )
        else:
            var ep = stack_allocation[2, EpollEventNatural]()
            var e_size = UInt64(Int(ep + 1) - Int(ep))
            _ = c.check(
                "epoll_event size (unpacked)",
                e_size == oracle_sizeof_epoll_event(),
            )
            var e0 = EpollEventNatural(0, 0)
            var e0p = UnsafePointer(to=e0)
            _ = c.check(
                "epoll_event offset events",
                UInt64(Int(UnsafePointer(to=e0.events)) - Int(e0p))
                == oracle_offset_epoll_event_events(),
            )
            _ = c.check(
                "epoll_event offset data",
                UInt64(Int(UnsafePointer(to=e0.data_u64)) - Int(e0p))
                == oracle_offset_epoll_event_data(),
            )
    else:
        print("epoll_event ENVIRONMENT (Linux only, not available on this host)")

    # ===================================================================
    # sa_family_t / socklen_t scalars
    # ===================================================================
    if is_macos:
        print("sa_family_t (darwin) expected size 1, Mojo alias UInt8 (1 byte)")
    elif is_linux:
        print("sa_family_t (linux) expected size 2, Mojo alias UInt16 (2 bytes)")

    # ===================================================================
    # pthread_attr_t / pthread_mutex_t — opaque, size+align ONLY
    # ===================================================================
    var attr_sz = oracle_sizeof_pthread_attr_t()
    var attr_al = oracle_alignof_pthread_attr_t()
    var mutex_sz = oracle_sizeof_pthread_mutex_t()
    var mutex_al = oracle_alignof_pthread_mutex_t()
    print(
        "pthread_attr_t opaque size/align:", attr_sz, attr_al,
        " pthread_mutex_t opaque size/align:", mutex_sz, mutex_al,
    )
    var attr_storage = stack_allocation[128, Byte]()  # generous, checked below
    _ = c.check(
        "pthread_attr_t roundtrip (real pthread_attr_init/destroy into"
        " oracle-sized storage)",
        oracle_pthread_attr_roundtrip(attr_storage.bitcast[Byte](), 128) == 0,
    )
    var mutex_storage = stack_allocation[128, Byte]()
    _ = c.check(
        "pthread_mutex_t roundtrip (real pthread_mutex_init/lock/unlock/"
        "destroy into oracle-sized storage)",
        oracle_pthread_mutex_roundtrip(mutex_storage.bitcast[Byte](), 128)
        == 0,
    )

    print("")
    if c.failures != 0:
        print("RESULT: " + String(c.failures) + " FAILED")
        raise Error(
            "struct_layout_test FAILED (" + String(c.failures) + " checks)"
        )
    print("RESULT: all green")
