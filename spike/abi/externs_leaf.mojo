# spike/abi/externs_leaf.mojo — M1.2 (#124) raw extern bindings, LEAF MODULE.
#
# Same discipline as every other externs.mojo in this repo (precedent #49,
# echoed in mojito_sys/io/externs.mojo and mojito_sys/sync/externs.mojo):
# ONLY @extern declarations, the comptime pointer aliases they need, and
# tiny non-raising probe_* call shims — no imports, no Movable structs, no
# raise sites, no control flow. b2's cross-module lowering misbinds extern
# call arguments when the DECLARING module also hosts Movable structs
# and/or raising machinery; this file stays pure specifically so it is
# NOT a confound when spike/abi/ordinary_frame_test.mojo goes looking for
# whether that same defect reproduces for libc/OS calls (as opposed to the
# mjs_* calls #49 was originally about).
#
# Covers BOTH oracle.c's helper surface (fill/check/sizeof/alignof/offset
# getters, the libc-call oracle) and the RAW libc/OS entry points issue
# #124 names directly (mmap/munmap/mprotect/sysconf/clock_gettime/
# mach_absolute_time/mach_timebase_info/socket/close/read/write/recv/send/
# fcntl/open/ioctl/the errno accessor). Both link against whatever the
# caller passes via -Xlinker: oracle.c's dylib provides the oracle_*
# symbols, and libc/libSystem provides everything else (no -Xlinker needed
# for those — they resolve against the process's own libc).

comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]
comptime I32Slot = UnsafePointer[Int32, MutAnyOrigin]
comptime U64Slot = UnsafePointer[UInt64, MutAnyOrigin]

# A minimal by-value struct shape duplicated here (not imported from
# types.mojo) so this module stays import-free per the leaf contract.
# Field-for-field identical to types.Timespec; only used for the by-value
# argument/return ABI probes below.
struct LeafTimespec:
    var tv_sec: Int64
    var tv_nsec: Int64

    def __init__(out self, tv_sec: Int64, tv_nsec: Int64):
        self.tv_sec = tv_sec
        self.tv_nsec = tv_nsec


# ---- oracle.c: struct getters (size/align/offset) --------------------------

@extern("oracle_sizeof_timespec")
def oracle_sizeof_timespec() abi("C") -> UInt64: ...
@extern("oracle_alignof_timespec")
def oracle_alignof_timespec() abi("C") -> UInt64: ...
@extern("oracle_offset_timespec_tv_sec")
def oracle_offset_timespec_tv_sec() abi("C") -> UInt64: ...
@extern("oracle_offset_timespec_tv_nsec")
def oracle_offset_timespec_tv_nsec() abi("C") -> UInt64: ...

@extern("oracle_sizeof_timeval")
def oracle_sizeof_timeval() abi("C") -> UInt64: ...
@extern("oracle_alignof_timeval")
def oracle_alignof_timeval() abi("C") -> UInt64: ...
@extern("oracle_offset_timeval_tv_sec")
def oracle_offset_timeval_tv_sec() abi("C") -> UInt64: ...
@extern("oracle_offset_timeval_tv_usec")
def oracle_offset_timeval_tv_usec() abi("C") -> UInt64: ...
@extern("oracle_fieldsizeof_timeval_tv_usec")
def oracle_fieldsizeof_timeval_tv_usec() abi("C") -> UInt64: ...

@extern("oracle_sizeof_sa_family_t")
def oracle_sizeof_sa_family_t() abi("C") -> UInt64: ...
@extern("oracle_sizeof_socklen_t")
def oracle_sizeof_socklen_t() abi("C") -> UInt64: ...

@extern("oracle_sizeof_sockaddr_in")
def oracle_sizeof_sockaddr_in() abi("C") -> UInt64: ...
@extern("oracle_alignof_sockaddr_in")
def oracle_alignof_sockaddr_in() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in_sin_family")
def oracle_offset_sockaddr_in_sin_family() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in_sin_port")
def oracle_offset_sockaddr_in_sin_port() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in_sin_addr")
def oracle_offset_sockaddr_in_sin_addr() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in_sin_zero")
def oracle_offset_sockaddr_in_sin_zero() abi("C") -> UInt64: ...
@extern("oracle_has_sin_len")
def oracle_has_sin_len() abi("C") -> Int32: ...
@extern("oracle_fieldsizeof_sockaddr_in_sin_family")
def oracle_fieldsizeof_sockaddr_in_sin_family() abi("C") -> UInt64: ...

@extern("oracle_sizeof_sockaddr_in6")
def oracle_sizeof_sockaddr_in6() abi("C") -> UInt64: ...
@extern("oracle_alignof_sockaddr_in6")
def oracle_alignof_sockaddr_in6() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in6_sin6_family")
def oracle_offset_sockaddr_in6_sin6_family() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in6_sin6_port")
def oracle_offset_sockaddr_in6_sin6_port() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in6_sin6_flowinfo")
def oracle_offset_sockaddr_in6_sin6_flowinfo() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in6_sin6_addr")
def oracle_offset_sockaddr_in6_sin6_addr() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_in6_sin6_scope_id")
def oracle_offset_sockaddr_in6_sin6_scope_id() abi("C") -> UInt64: ...

@extern("oracle_sizeof_sockaddr_un")
def oracle_sizeof_sockaddr_un() abi("C") -> UInt64: ...
@extern("oracle_alignof_sockaddr_un")
def oracle_alignof_sockaddr_un() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_un_sun_family")
def oracle_offset_sockaddr_un_sun_family() abi("C") -> UInt64: ...
@extern("oracle_offset_sockaddr_un_sun_path")
def oracle_offset_sockaddr_un_sun_path() abi("C") -> UInt64: ...
@extern("oracle_sun_path_capacity")
def oracle_sun_path_capacity() abi("C") -> UInt64: ...

@extern("oracle_sizeof_iovec")
def oracle_sizeof_iovec() abi("C") -> UInt64: ...
@extern("oracle_alignof_iovec")
def oracle_alignof_iovec() abi("C") -> UInt64: ...
@extern("oracle_offset_iovec_iov_base")
def oracle_offset_iovec_iov_base() abi("C") -> UInt64: ...
@extern("oracle_offset_iovec_iov_len")
def oracle_offset_iovec_iov_len() abi("C") -> UInt64: ...

@extern("oracle_has_kevent")
def oracle_has_kevent() abi("C") -> Int32: ...
@extern("oracle_sizeof_kevent")
def oracle_sizeof_kevent() abi("C") -> UInt64: ...
@extern("oracle_alignof_kevent")
def oracle_alignof_kevent() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_ident")
def oracle_offset_kevent_ident() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_filter")
def oracle_offset_kevent_filter() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_flags")
def oracle_offset_kevent_flags() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_fflags")
def oracle_offset_kevent_fflags() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_data")
def oracle_offset_kevent_data() abi("C") -> UInt64: ...
@extern("oracle_offset_kevent_udata")
def oracle_offset_kevent_udata() abi("C") -> UInt64: ...

@extern("oracle_has_epoll_event")
def oracle_has_epoll_event() abi("C") -> Int32: ...
@extern("oracle_sizeof_epoll_event")
def oracle_sizeof_epoll_event() abi("C") -> UInt64: ...
@extern("oracle_alignof_epoll_event")
def oracle_alignof_epoll_event() abi("C") -> UInt64: ...
@extern("oracle_offset_epoll_event_events")
def oracle_offset_epoll_event_events() abi("C") -> UInt64: ...
@extern("oracle_offset_epoll_event_data")
def oracle_offset_epoll_event_data() abi("C") -> UInt64: ...
@extern("oracle_epoll_event_is_packed")
def oracle_epoll_event_is_packed() abi("C") -> Int32: ...

@extern("oracle_sizeof_pthread_attr_t")
def oracle_sizeof_pthread_attr_t() abi("C") -> UInt64: ...
@extern("oracle_alignof_pthread_attr_t")
def oracle_alignof_pthread_attr_t() abi("C") -> UInt64: ...
@extern("oracle_sizeof_pthread_mutex_t")
def oracle_sizeof_pthread_mutex_t() abi("C") -> UInt64: ...
@extern("oracle_alignof_pthread_mutex_t")
def oracle_alignof_pthread_mutex_t() abi("C") -> UInt64: ...
@extern("oracle_pthread_attr_roundtrip")
def oracle_pthread_attr_roundtrip(storage: ByteBuf, cap: UInt64) abi("C") -> Int32: ...
@extern("oracle_pthread_mutex_roundtrip")
def oracle_pthread_mutex_roundtrip(storage: ByteBuf, cap: UInt64) abi("C") -> Int32: ...

# ---- oracle.c: fill/check round-trip (pointer form, every struct) ----------

@extern("oracle_fill_timespec")
def oracle_fill_timespec(p: ByteBuf) abi("C"): ...
@extern("oracle_check_timespec")
def oracle_check_timespec(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_timeval")
def oracle_fill_timeval(p: ByteBuf) abi("C"): ...
@extern("oracle_check_timeval")
def oracle_check_timeval(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_sockaddr_in")
def oracle_fill_sockaddr_in(p: ByteBuf) abi("C"): ...
@extern("oracle_check_sockaddr_in")
def oracle_check_sockaddr_in(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_sockaddr_in6")
def oracle_fill_sockaddr_in6(p: ByteBuf) abi("C"): ...
@extern("oracle_check_sockaddr_in6")
def oracle_check_sockaddr_in6(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_sockaddr_un")
def oracle_fill_sockaddr_un(p: ByteBuf) abi("C"): ...
@extern("oracle_check_sockaddr_un")
def oracle_check_sockaddr_un(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_iovec")
def oracle_fill_iovec(p: ByteBuf) abi("C"): ...
@extern("oracle_check_iovec")
def oracle_check_iovec(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_kevent")
def oracle_fill_kevent(p: ByteBuf) abi("C"): ...
@extern("oracle_check_kevent")
def oracle_check_kevent(p: ByteBuf) abi("C") -> Int32: ...
@extern("oracle_fill_epoll_event")
def oracle_fill_epoll_event(p: ByteBuf) abi("C"): ...
@extern("oracle_check_epoll_event")
def oracle_check_epoll_event(p: ByteBuf) abi("C") -> Int32: ...

# ---- oracle.c: by-value argument-passing probes ----------------------------

@extern("oracle_timespec_sum_byval")
def oracle_timespec_sum_byval(ts: LeafTimespec) abi("C") -> Int64: ...
@extern("oracle_make_timespec_byval")
def oracle_make_timespec_byval(sec: Int64, nsec: Int64) abi("C") -> LeafTimespec: ...

# ---- oracle.c: platform-numeric constants ----------------------------------

@extern("oracle_const_AF_INET")
def oracle_const_AF_INET() abi("C") -> Int32: ...
@extern("oracle_const_AF_INET6")
def oracle_const_AF_INET6() abi("C") -> Int32: ...
@extern("oracle_const_AF_UNIX")
def oracle_const_AF_UNIX() abi("C") -> Int32: ...
@extern("oracle_const_SOCK_STREAM")
def oracle_const_SOCK_STREAM() abi("C") -> Int32: ...
@extern("oracle_const_SOCK_DGRAM")
def oracle_const_SOCK_DGRAM() abi("C") -> Int32: ...
@extern("oracle_const_PROT_NONE")
def oracle_const_PROT_NONE() abi("C") -> Int32: ...
@extern("oracle_const_PROT_READ")
def oracle_const_PROT_READ() abi("C") -> Int32: ...
@extern("oracle_const_PROT_WRITE")
def oracle_const_PROT_WRITE() abi("C") -> Int32: ...
@extern("oracle_const_MAP_PRIVATE")
def oracle_const_MAP_PRIVATE() abi("C") -> Int32: ...
@extern("oracle_const_MAP_ANON")
def oracle_const_MAP_ANON() abi("C") -> Int32: ...
@extern("oracle_const_SC_PAGESIZE")
def oracle_const_SC_PAGESIZE() abi("C") -> Int32: ...
@extern("oracle_const_O_NONBLOCK")
def oracle_const_O_NONBLOCK() abi("C") -> Int32: ...
@extern("oracle_const_O_RDWR")
def oracle_const_O_RDWR() abi("C") -> Int32: ...
@extern("oracle_const_O_CREAT")
def oracle_const_O_CREAT() abi("C") -> Int32: ...
@extern("oracle_const_F_GETFL")
def oracle_const_F_GETFL() abi("C") -> Int32: ...
@extern("oracle_const_F_SETFL")
def oracle_const_F_SETFL() abi("C") -> Int32: ...
@extern("oracle_const_CLOCK_MONOTONIC")
def oracle_const_CLOCK_MONOTONIC() abi("C") -> Int32: ...
@extern("oracle_const_EBADF")
def oracle_const_EBADF() abi("C") -> Int32: ...
@extern("oracle_const_EINVAL")
def oracle_const_EINVAL() abi("C") -> Int32: ...
@extern("oracle_const_EAGAIN")
def oracle_const_EAGAIN() abi("C") -> Int32: ...
@extern("oracle_const_FIONREAD")
def oracle_const_FIONREAD() abi("C") -> UInt64: ...

# ---- oracle.c: libc-call oracle (the comparison partner) -------------------

@extern("oracle_call_pagesize")
def oracle_call_pagesize() abi("C") -> Int64: ...
@extern("oracle_call_mmap_anon")
def oracle_call_mmap_anon(length: UInt64, prot: Int32) abi("C") -> UInt64: ...
@extern("oracle_call_munmap")
def oracle_call_munmap(addr: UInt64, length: UInt64) abi("C") -> Int32: ...
@extern("oracle_call_mprotect")
def oracle_call_mprotect(addr: UInt64, length: UInt64, prot: Int32) abi("C") -> Int32: ...
@extern("oracle_call_clock_monotonic_ns")
def oracle_call_clock_monotonic_ns(out_ns: U64Slot) abi("C") -> Int32: ...
@extern("oracle_call_mach_monotonic_ns")
def oracle_call_mach_monotonic_ns(out_ns: U64Slot) abi("C") -> Int32: ...
@extern("oracle_call_socket")
def oracle_call_socket(family: Int32, sock_type: Int32) abi("C") -> Int32: ...
@extern("oracle_call_close")
def oracle_call_close(fd: Int32) abi("C") -> Int32: ...
@extern("oracle_call_read")
def oracle_call_read(fd: Int32, buf: ByteBuf, length: UInt64) abi("C") -> Int64: ...
@extern("oracle_call_write")
def oracle_call_write(fd: Int32, buf: ByteBuf, length: UInt64) abi("C") -> Int64: ...
@extern("oracle_call_recv")
def oracle_call_recv(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) abi("C") -> Int64: ...
@extern("oracle_call_send")
def oracle_call_send(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) abi("C") -> Int64: ...
@extern("oracle_force_ebadf")
def oracle_force_ebadf() abi("C") -> Int32: ...
@extern("oracle_force_einval_mprotect")
def oracle_force_einval_mprotect(misaligned_addr: UInt64) abi("C") -> Int32: ...
@extern("oracle_force_eagain_recv")
def oracle_force_eagain_recv(nonblocking_fd: Int32) abi("C") -> Int32: ...
@extern("oracle_make_nonblocking_pair")
def oracle_make_nonblocking_pair(out_a: I32Slot, out_b: I32Slot) abi("C") -> Int32: ...

# ---- RAW libc/OS entry points, called with NO oracle wrapper in between ----
# This is the actual subject of the spike's second half: these bind
# straight to libc/libSystem, the same symbols native/posix/*.c calls
# today, with no mojito-sys C layer anywhere in the chain.

@extern("mmap")
def mjo_mmap(
    addr: UInt64, length: UInt64, prot: Int32, flags: Int32, fd: Int32, offset: Int64
) abi("C") -> UInt64: ...
@extern("munmap")
def mjo_munmap(addr: UInt64, length: UInt64) abi("C") -> Int32: ...
@extern("mprotect")
def mjo_mprotect(addr: UInt64, length: UInt64, prot: Int32) abi("C") -> Int32: ...
@extern("sysconf")
def mjo_sysconf(name: Int32) abi("C") -> Int64: ...
@extern("clock_gettime")
def mjo_clock_gettime(clk_id: Int32, tp: ByteBuf) abi("C") -> Int32: ...

@extern("mach_absolute_time")
def mjo_mach_absolute_time() abi("C") -> UInt64: ...
@extern("mach_timebase_info")
def mjo_mach_timebase_info(info: ByteBuf) abi("C") -> Int32: ...

@extern("socket")
def mjo_socket(domain: Int32, sock_type: Int32, protocol: Int32) abi("C") -> Int32: ...
@extern("close")
def mjo_close(fd: Int32) abi("C") -> Int32: ...
# `read` is declared directly (works fine — see below); `write` is NOT,
# on purpose. DEFECT FOUND, filed as mojito-sys#195 with a minimal
# reproducer at docs/defects/m1-2-write-extern-stdio-conflict.mojo: a
# module that also uses `print()` (or any std.io write path) pulls in the
# standard library's OWN internal `@extern("write")` binding
# (std/io/file_descriptor.mojo — FileDescriptor.write), and Mojo's extern
# mechanism treats the C SYMBOL as the uniqueness key across the WHOLE
# compiled program, not per module. Declaring `write` a second time here
# — even matching the stdlib's own word-sized/opaque-pointer signature
# EXACTLY (`Int, UnsafePointer[NoneType, ...], Int -> Int`, confirmed via
# bisection to be what the stdlib itself uses, since a WIDTH-only match,
# e.g. UInt64 count, fails one error earlier with "conflicting
# signature") — still fails LLVM lowering with "existing function with
# conflicting attributes" the moment BOTH call sites are actually
# exercised (an unused declaration is dead-code-eliminated and never
# trips this, which cost real time to find here). Some non-signature
# attribute Mojo attaches to the `abi("C")` @extern surface differs from
# whatever the stdlib's internal `external_call[...]` intrinsic sets, and
# nothing in the bundled Modular guidance names what that attribute is or
# how to match it.
#
# `read` does NOT hit this: FileDescriptor exposes no `.read()` method on
# this toolchain at all, so there is no competing internal call site to
# conflict with — confirmed by bisection (declaring+calling `read` alone
# alongside `print()`/`FileDescriptor.write` compiles and runs cleanly).
# So the asymmetric, empirically-forced shape here is real: `read` is a
# normal @extern below; `write` is reached ONLY through
# `std.io.FileDescriptor.write()` (spike/abi/libc_calls_test.mojo) — the
# stdlib's own direct, unwrapped binding to the same libc symbol, not a
# second one declared here.
@extern("read")
def mjo_read(fd: Int32, buf: ByteBuf, count: UInt64) abi("C") -> Int64: ...
@extern("recv")
def mjo_recv(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) abi("C") -> Int64: ...
@extern("send")
def mjo_send(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) abi("C") -> Int64: ...

# errno accessor — a THREAD-LOCAL macro expanding to a function call on
# both target platforms (issue #124's own framing). Declared directly:
# Darwin's libc exposes __error() -> int*; glibc exposes
# __errno_location() -> int*. Both selected by CompilationTarget in the
# TEST files (this leaf module declares both names unconditionally; only
# the one that resolves against the host's libc is ever called).
@extern("__error")
def mjo_error_ptr_macos() abi("C") -> UInt64: ...
@extern("__errno_location")
def mjo_errno_location_linux() abi("C") -> UInt64: ...

# fcntl/open/ioctl are VARIADIC/macro-shaped in their C prototypes
# (issue #124: "reachable or explicitly listed as needing a shim"). Probed
# here by declaring FIXED-ARITY forms that match how they are actually
# invoked at each call site — the same trick C FFI bindings use for
# variadic functions when the call site's argument shape is known ahead
# of time (the args that matter physically occupy the same registers a
# real variadic call site would put them in).
#
# DEFECT/LIMITATION FOUND (not a crash, an expressiveness constraint;
# filed as mojito-sys#197 alongside the related no-module-level-
# conditional-compilation finding): Mojo b2 refuses to declare the SAME
# C symbol under two different @extern arities in one module —
# `@extern("fcntl")` on both a 2-arg and
# a 3-arg local Mojo function is a compile-time "duplicate functions
# named 'fcntl'" error, even though the two Mojo-side names differ. The
# uniqueness key is the underlying C SYMBOL, not the local declaration
# name. So this file declares only ONE (the widest) fixed arity per
# symbol — fcntl(fd, cmd, arg) and open(path, flags, mode) always take
# 3 args, with the trailing arg simply unused/zero for call sites that
# need fewer (F_GETFL doesn't consult it; this is safe because a
# variadic callee that reads FEWER args than the caller supplied never
# touches the extra ones — the unsafe direction is supplying fewer args
# than the callee reads, not more). This is what a real production
# binding would do anyway; it just means "declare 2-arg AND 3-arg forms
# side by side to probe both shapes" needs separate compilation units,
# not one leaf module.
@extern("fcntl")
def mjo_fcntl(fd: Int32, cmd: Int32, arg: Int32) abi("C") -> Int32: ...
@extern("open")
def mjo_open(path: ByteBuf, flags: Int32, mode: Int32) abi("C") -> Int32: ...
@extern("ioctl")
def mjo_ioctl3(fd: Int32, request: UInt64, arg: I32Slot) abi("C") -> Int32: ...


# ---- non-raising call shims (leaf-module boundary, repo convention) --------
# Every extern above is invoked ONLY through one of these; wrapper/test
# modules decode/raise after the call returns, mirroring
# mojito_sys/io/externs.mojo's probe_* shims exactly.

def probe_mmap(addr: UInt64, length: UInt64, prot: Int32, flags: Int32, fd: Int32, offset: Int64) -> UInt64:
    return mjo_mmap(addr, length, prot, flags, fd, offset)

def probe_munmap(addr: UInt64, length: UInt64) -> Int32:
    return mjo_munmap(addr, length)

def probe_mprotect(addr: UInt64, length: UInt64, prot: Int32) -> Int32:
    return mjo_mprotect(addr, length, prot)

def probe_sysconf(name: Int32) -> Int64:
    return mjo_sysconf(name)

def probe_clock_gettime(clk_id: Int32, tp: ByteBuf) -> Int32:
    return mjo_clock_gettime(clk_id, tp)

def probe_mach_absolute_time() -> UInt64:
    return mjo_mach_absolute_time()

def probe_mach_timebase_info(info: ByteBuf) -> Int32:
    return mjo_mach_timebase_info(info)

def probe_socket(domain: Int32, sock_type: Int32, protocol: Int32) -> Int32:
    return mjo_socket(domain, sock_type, protocol)

def probe_close(fd: Int32) -> Int32:
    return mjo_close(fd)

def probe_read(fd: Int32, buf: ByteBuf, count: UInt64) -> Int64:
    return mjo_read(fd, buf, count)

def probe_recv(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) -> Int64:
    return mjo_recv(fd, buf, length, flags)

def probe_send(fd: Int32, buf: ByteBuf, length: UInt64, flags: Int32) -> Int64:
    return mjo_send(fd, buf, length, flags)

def probe_error_ptr_macos() -> UInt64:
    return mjo_error_ptr_macos()

def probe_errno_location_linux() -> UInt64:
    return mjo_errno_location_linux()

# F_GETFL-style 2-arg call sites pass 0 for the unused trailing arg (see
# the DEFECT/LIMITATION note above — safe because the callee never reads
# it for that command).
def probe_fcntl2(fd: Int32, cmd: Int32) -> Int32:
    return mjo_fcntl(fd, cmd, 0)

def probe_fcntl3(fd: Int32, cmd: Int32, arg: Int32) -> Int32:
    return mjo_fcntl(fd, cmd, arg)

def probe_open2(path: ByteBuf, flags: Int32) -> Int32:
    return mjo_open(path, flags, 0)

def probe_open3(path: ByteBuf, flags: Int32, mode: Int32) -> Int32:
    return mjo_open(path, flags, mode)

def probe_ioctl3(fd: Int32, request: UInt64, arg: I32Slot) -> Int32:
    return mjo_ioctl3(fd, request, arg)

def probe_timespec_sum_byval(sec: Int64, nsec: Int64) -> Int64:
    return oracle_timespec_sum_byval(LeafTimespec(sec, nsec))
