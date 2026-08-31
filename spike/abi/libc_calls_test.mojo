# spike/abi/libc_calls_test.mojo — M1.2 (#124) direct-libc-call half.
#
# Every call here goes STRAIGHT to libc/libSystem via externs_leaf.mojo's
# raw @extern bindings — no mojito-sys C wrapper, no oracle indirection in
# the call itself. oracle.c is used only as the COMPARISON PARTNER: it
# makes the identical call for the identical inputs so the Mojo-side
# result (return value AND errno) can be diffed against it.
#
# Covers issue #124's minimum set: mmap/munmap/mprotect + page size,
# clock_gettime(CLOCK_MONOTONIC) (and mach_absolute_time +
# mach_timebase_info on macOS, the "honest path" alternative), socket/
# close/read/write/recv/send. Plus the three things the issue says need
# proving beyond "it returned zero":
#   - errno read correctly from Mojo (both accessor functions declared
#     directly: __error on macOS, __errno_location on Linux) across THREE
#     distinct failure modes (EBADF/EINVAL/EAGAIN);
#   - fcntl/open/ioctl reachability as fixed-arity declarations of
#     variadic/macro-shaped C entry points;
#   - this file is NOT a leaf module (it imports types.mojo and
#     externs_leaf.mojo, raises, and branches on CompilationTarget before
#     making these calls) — see ordinary_frame_test.mojo for the dedicated
#     leaf-module-constraint probe; this file's own success already shows
#     these SAME libc calls work fine from an ordinary frame when the
#     call itself isn't co-located with a Movable/raising struct the way
#     #49's reproducer required.

from std.io import FileDescriptor
from std.memory import stack_allocation
from std.sys import CompilationTarget

from types import Timespec
from externs_leaf import (
    probe_mmap,
    probe_munmap,
    probe_mprotect,
    probe_sysconf,
    probe_clock_gettime,
    probe_mach_absolute_time,
    probe_mach_timebase_info,
    probe_socket,
    probe_close,
    probe_read,
    probe_recv,
    probe_send,
    probe_error_ptr_macos,
    probe_errno_location_linux,
    probe_fcntl2,
    probe_fcntl3,
    probe_open2,
    probe_open3,
    probe_ioctl3,
    oracle_const_SC_PAGESIZE,
    oracle_const_PROT_READ,
    oracle_const_PROT_WRITE,
    oracle_const_PROT_NONE,
    oracle_const_MAP_PRIVATE,
    oracle_const_MAP_ANON,
    oracle_const_CLOCK_MONOTONIC,
    oracle_const_AF_INET,
    oracle_const_SOCK_STREAM,
    oracle_const_O_NONBLOCK,
    oracle_const_O_RDWR,
    oracle_const_F_GETFL,
    oracle_const_F_SETFL,
    oracle_const_EBADF,
    oracle_const_EINVAL,
    oracle_const_EAGAIN,
    oracle_const_FIONREAD,
    oracle_call_pagesize,
    oracle_call_clock_monotonic_ns,
    oracle_call_mach_monotonic_ns,
    oracle_force_ebadf,
    oracle_force_einval_mprotect,
    oracle_force_eagain_recv,
    oracle_make_nonblocking_pair,
)

comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]
comptime I32Slot = UnsafePointer[Int32, MutAnyOrigin]


struct Checker:
    var failures: Int

    def __init__(out self):
        self.failures = 0

    def check(mut self, name: String, cond: Bool) -> Bool:
        print(name + " " + ("PASS" if cond else "FAIL"))
        if not cond:
            self.failures += 1
        return cond


# Reads the calling thread's errno through the platform's REAL accessor —
# __error() on macOS, __errno_location() on Linux — called directly, no
# mojito-sys wrapper anywhere. This is the thing issue #124 says has to be
# proven: errno is a thread-local macro expanding to a function call on
# both targets, and the whole 0-or-negative-errno ABI contract collapses
# if Mojo cannot read it correctly.
#
# STRUCTURAL FINDING (real, load-bearing for the rest of the migration):
# selecting between the two accessors with a RUNTIME `if` (as an earlier
# draft of this function did) fails to link/JIT on whichever platform
# does NOT provide the OTHER platform's symbol — Mojo eagerly resolves
# EVERY externally-called symbol for the whole compiled program, dead
# runtime branch or not (confirmed directly: this exact shape, but with
# `if is_macos:`/`else:`, fails on macOS with "Symbols not found:
# [___errno_location]" even though that branch never executes here).
# `comptime if` is the fix: unlike a runtime `if`, a `comptime if` branch
# not taken FOR THIS COMPILATION TARGET is pruned entirely at compile
# time, so the untaken accessor's call site — and with it the need to
# resolve its symbol — never reaches the linker (confirmed directly: the
# identical two declarations plus a `comptime if` selector at the call
# site compiles and links cleanly). This is also confirmation, in the
# structural-constraint sense issue #124 asks for, that Mojo b2 has NO
# module-level conditional-compilation mechanism (a bare `comptime if`
# cannot wrap a top-level declaration — "must be contained in a
# function" — and `@extern` refuses a comptime-computed symbol-name
# string, only a literal — filed as mojito-sys#197 alongside the related
# fact that one module cannot declare two different arities of the same
# symbol either): declaring both platforms' externs and
# `comptime if`-selecting the CALL is the only portable shape, and it is
# the pattern the rest of this migration should use for every other
# platform-exclusive raw symbol (kqueue vs epoll, mach vs clock_gettime,
# and so on) — not the runtime-`if`-branch shape this repo's existing
# mjs_* wrappers get away with only because their C side normalizes
# platform absence into a real, always-present -ENOSYS stub symbol,
# which isn't an option for an uncontrolled system symbol like
# __errno_location.
def read_errno() -> Int32:
    var addr: UInt64
    comptime if CompilationTarget().is_macos():
        addr = probe_error_ptr_macos()
    else:
        addr = probe_errno_location_linux()
    var p = UnsafePointer[Int32, MutAnyOrigin](unsafe_from_address=Int(addr))
    return p[0]


# read()/recv() on a NON-BLOCKING socket immediately after a same-process
# write()/send() is not guaranteed to see the bytes on the first attempt —
# delivery across a loopback connection still goes through the kernel's
# own scheduling, and EAGAIN this early is a normal status, not a failure
# (the whole point of a non-blocking socket). Retries a bounded number of
# times on EAGAIN before giving up, exactly the shape a real reactor uses.
def retry_on_eagain(fd: Int32, buf: ByteBuf, cap: UInt64, use_recv: Bool) -> Int64:
    var attempt = 0
    while attempt < 10000:
        var n: Int64
        if use_recv:
            n = probe_recv(fd, buf, cap, 0)
        else:
            n = probe_read(fd, buf, cap)
        if n != -1:
            return n
        if read_errno() != oracle_const_EAGAIN():
            return n
        attempt += 1
    return -1


def main() raises:
    var c = Checker()
    var is_macos = CompilationTarget().is_macos()
    var is_linux = CompilationTarget().is_linux()

    # ===================================================================
    # page size
    # ===================================================================
    var page_size = probe_sysconf(oracle_const_SC_PAGESIZE())
    _ = c.check(
        "sysconf(_SC_PAGESIZE) direct == oracle's own sysconf call",
        page_size == oracle_call_pagesize(),
    )
    _ = c.check("page_size is positive", page_size > 0)

    # ===================================================================
    # mmap / munmap / mprotect — reserve, use, reprotect, release, direct
    # ===================================================================
    var prot_rw = oracle_const_PROT_READ() | oracle_const_PROT_WRITE()
    var flags_anon = oracle_const_MAP_PRIVATE() | oracle_const_MAP_ANON()
    var addr = probe_mmap(0, UInt64(page_size), prot_rw, flags_anon, -1, 0)
    _ = c.check("mmap direct succeeded (nonzero address)", addr != 0)
    var mp = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(addr))
    mp[0] = 0x42
    mp[Int(page_size) - 1] = 0x99
    _ = c.check(
        "mmap'd region is genuinely writable/readable (first+last byte)",
        mp[0] == 0x42 and mp[Int(page_size) - 1] == 0x99,
    )
    var mprc = probe_mprotect(addr, UInt64(page_size), oracle_const_PROT_READ())
    _ = c.check("mprotect to READ-only direct succeeded", mprc == 0)
    _ = c.check(
        "region still readable after mprotect(READ)", mp[0] == 0x42
    )
    var unmprc = probe_mprotect(addr, UInt64(page_size), prot_rw)
    _ = c.check("mprotect back to READ|WRITE direct succeeded", unmprc == 0)
    var munrc = probe_munmap(addr, UInt64(page_size))
    _ = c.check("munmap direct succeeded", munrc == 0)

    # ===================================================================
    # clock_gettime(CLOCK_MONOTONIC) — direct, diffed against the oracle's
    # own reading (both taken back-to-back; must be close and the second
    # Mojo reading must never go backwards relative to the first).
    # ===================================================================
    var ts1 = stack_allocation[1, Timespec]()
    var g1 = probe_clock_gettime(oracle_const_CLOCK_MONOTONIC(), ts1.bitcast[Byte]())
    _ = c.check("clock_gettime(CLOCK_MONOTONIC) direct rc == 0", g1 == 0)
    var ns1 = UInt64(ts1[0].tv_sec) * 1_000_000_000 + UInt64(ts1[0].tv_nsec)
    var oracle_ns_slot = stack_allocation[1, UInt64]()
    var orc = oracle_call_clock_monotonic_ns(oracle_ns_slot)
    _ = c.check("oracle clock_gettime rc == 0", orc == 0)
    var oracle_ns = oracle_ns_slot[0]
    var delta = ns1 - oracle_ns if ns1 > oracle_ns else oracle_ns - ns1
    # Both calls happen microseconds apart on the same clock domain; one
    # second of slack is generous enough to be robust under CI scheduling
    # noise while still catching a genuinely wrong clock (wrong domain,
    # wrong units, garbage read).
    _ = c.check(
        "direct clock_gettime agrees with oracle's own reading (within 1s)",
        delta < 1_000_000_000,
    )
    var ts2 = stack_allocation[1, Timespec]()
    _ = probe_clock_gettime(oracle_const_CLOCK_MONOTONIC(), ts2.bitcast[Byte]())
    var ns2 = UInt64(ts2[0].tv_sec) * 1_000_000_000 + UInt64(ts2[0].tv_nsec)
    _ = c.check("clock_gettime is monotonic non-decreasing", ns2 >= ns1)

    # ===================================================================
    # mach_absolute_time + mach_timebase_info — macOS's "honest path"
    # alternative (issue #124). Direct calls, diffed against the oracle's
    # own mach reading the same way as clock_gettime above.
    # ===================================================================
    if is_macos:
        var tb_buf = stack_allocation[2, UInt32]()  # {numer, denom}
        var tb_rc = probe_mach_timebase_info(tb_buf.bitcast[Byte]())
        _ = c.check("mach_timebase_info direct rc == KERN_SUCCESS (0)", tb_rc == 0)
        var numer = tb_buf[0]
        var denom = tb_buf[1]
        _ = c.check("mach_timebase_info denom nonzero", denom != 0)
        var raw = probe_mach_absolute_time()
        var mach_ns = (UInt64(raw) * UInt64(numer)) // UInt64(denom)
        var mach_oracle_slot = stack_allocation[1, UInt64]()
        var mrc = oracle_call_mach_monotonic_ns(mach_oracle_slot)
        _ = c.check("oracle mach_monotonic_ns rc == 0", mrc == 0)
        var mach_oracle_ns = mach_oracle_slot[0]
        var mach_delta = (
            mach_ns - mach_oracle_ns if mach_ns > mach_oracle_ns
            else mach_oracle_ns - mach_ns
        )
        _ = c.check(
            "direct mach_absolute_time+timebase agrees with oracle (within 1s)",
            mach_delta < 1_000_000_000,
        )
        # NOTE: deliberately NOT cross-checking mach_absolute_time's
        # absolute value against clock_gettime(CLOCK_MONOTONIC)'s — an
        # earlier draft of this test did and it failed: the two clocks
        # are not guaranteed to share an epoch (mach_absolute_time is
        # since-boot; POSIX only requires CLOCK_MONOTONIC to be
        # non-decreasing, not tied to any particular reference point), so
        # a large absolute delta between them is not itself a defect —
        # a test bug in an earlier draft, not a Mojo finding, and removed
        # rather than papered over with a looser threshold.

    # ===================================================================
    # socket / close
    # ===================================================================
    var fd = probe_socket(oracle_const_AF_INET(), oracle_const_SOCK_STREAM(), 0)
    _ = c.check("socket() direct succeeded (fd >= 0)", fd >= 0)
    var crc0 = probe_close(fd)
    _ = c.check("close() direct on a fresh socket succeeded", crc0 == 0)

    # ===================================================================
    # read/write + recv/send, both directions, over a real connected TCP
    # loopback pair the oracle sets up (both ends already non-blocking).
    #
    # `write` specifically goes through std.io.FileDescriptor rather than
    # a hand-declared @extern("write") — see externs_leaf.mojo's header
    # note and docs/defects/m1-2-write-extern-stdio-conflict.mojo: a
    # custom `write` binding conflicts with the stdlib's own internal one
    # the moment both this program's print() calls AND the custom binding
    # are actually exercised. `read` has no such stdlib competitor
    # (FileDescriptor exposes no `.read()` here) so it's a plain @extern.
    # ===================================================================
    var fd_a = stack_allocation[1, Int32]()
    var fd_b = stack_allocation[1, Int32]()
    var prc = oracle_make_nonblocking_pair(fd_a, fd_b)
    _ = c.check("oracle_make_nonblocking_pair succeeded", prc == 0)
    var client = fd_a[0]
    var server = fd_b[0]

    # FileDescriptor.write() returns None (no byte count) on this
    # toolchain; success is verified transitively by the read() below
    # actually receiving the 5 bytes.
    var client_fd = FileDescriptor(Int(client))
    client_fd.write("Hello")

    var rbuf = stack_allocation[16, Byte]()
    var rn = retry_on_eagain(server, rbuf.bitcast[Byte](), 16, False)
    _ = c.check("read() direct received the 5 bytes write() sent", rn == 5)
    _ = c.check(
        "read() payload matches byte-for-byte",
        rbuf[0] == 72 and rbuf[1] == 101 and rbuf[2] == 108
        and rbuf[3] == 108 and rbuf[4] == 111,
    )

    var sbuf = stack_allocation[3, Byte]()
    sbuf[0] = 89  # 'Y'
    sbuf[1] = 79  # 'O'
    sbuf[2] = 33  # '!'
    var sn = probe_send(server, sbuf.bitcast[Byte](), 3, 0)
    _ = c.check("send() direct sent all 3 bytes", sn == 3)

    var rvbuf = stack_allocation[16, Byte]()
    var rvn = retry_on_eagain(client, rvbuf.bitcast[Byte](), 16, True)
    _ = c.check("recv() direct received the 3 bytes send() sent", rvn == 3)
    _ = c.check(
        "recv() payload matches byte-for-byte",
        rvbuf[0] == 89 and rvbuf[1] == 79 and rvbuf[2] == 33,
    )

    # ===================================================================
    # variadic/macro-shaped entry points — fcntl/open/ioctl, reached via
    # FIXED-ARITY @extern declarations (issue #124: "reachable or
    # explicitly listed as needing a shim"). Exercised on the real
    # already-nonblocking `client` fd from the pair above.
    # ===================================================================
    var flags2 = probe_fcntl2(client, oracle_const_F_GETFL())
    _ = c.check("fcntl(fd, F_GETFL) [2-arg] direct succeeded", flags2 >= 0)
    _ = c.check(
        "fcntl(F_GETFL) sees the O_NONBLOCK the oracle set",
        (flags2 & oracle_const_O_NONBLOCK()) != 0,
    )
    var cleared = flags2 & ~oracle_const_O_NONBLOCK()
    var setrc = probe_fcntl3(client, oracle_const_F_SETFL(), cleared)
    _ = c.check("fcntl(fd, F_SETFL, flags) [3-arg] direct succeeded", setrc == 0)
    var flags2b = probe_fcntl2(client, oracle_const_F_GETFL())
    _ = c.check(
        "fcntl(F_SETFL) [3-arg] actually cleared O_NONBLOCK",
        (flags2b & oracle_const_O_NONBLOCK()) == 0,
    )
    # restore non-blocking so the errno probes below still see it
    _ = probe_fcntl3(client, oracle_const_F_SETFL(), flags2)

    var devnull = "/dev/null"
    var devnull_addr = Int(devnull.unsafe_ptr())
    var devnull_ptr = ByteBuf(unsafe_from_address=devnull_addr)

    var fd2 = probe_open2(devnull_ptr, oracle_const_O_RDWR())
    _ = c.check("open(path, flags) [2-arg] direct on /dev/null succeeded", fd2 >= 0)
    _ = c.check("close() the open(2-arg) fd", probe_close(fd2) == 0)

    var fd3 = probe_open3(devnull_ptr, oracle_const_O_RDWR(), 0)
    _ = c.check("open(path, flags, mode) [3-arg] direct on /dev/null succeeded", fd3 >= 0)
    _ = c.check("close() the open(3-arg) fd", probe_close(fd3) == 0)

    # DEFECT FOUND (real, minimally reproduced, filed as
    # mojito-sys#196 — see docs/defects/m1-2-ioctl-pointer-arg-lost.mojo):
    # ioctl(fd, FIONREAD, &n) [3-arg fixed form] reports SUCCESS (rc == 0)
    # but never writes through the pointer argument — `avail` stays at
    # its initial sentinel no matter how many times this is retried, with
    # a real byte genuinely queued the whole time (confirmed in isolation
    # down to a 20-line reproducer, independent of this file's retry
    # helper or its send/recv machinery). Bisected down to the ARGUMENT
    # ITSELF, not its type: the identical outcome (rc 0, no write-through)
    # happens whether `arg` is declared as a typed `UnsafePointer[Int32,
    # MutAnyOrigin]` or as a raw `UInt64` machine word carrying the same
    # address. The leading suspect (not proven from Mojo's own compiler
    # internals, but consistent with every observation): Apple's arm64
    # ABI requires arguments past a variadic function's last FIXED
    # parameter to be passed on the STACK, never in a register, while
    # `ioctl`'s C prototype is `int ioctl(int fd, unsigned long request,
    # ...)` — only 2 fixed parameters — so the real variadic-call-site
    # convention puts `arg` on the stack; a `@extern` declaration gives
    # Mojo no way to mark a parameter as "the variadic tail", so it
    # lowers all 3 parameters via the ordinary (register) convention, and
    # the real ioctl() implementation's own va_arg read of the stack
    # never sees a valid pointer — writing nowhere Mojo can observe,
    # while still returning the FIONREAD ioctl's own success code. fcntl
    # and open (both also nominally variadic in their C prototypes, both
    # exercised above) did NOT show this: their 3rd argument is a plain
    # scalar int, not a pointer, and this suite's F_SETFL check DID prove
    # the value reaches the real fcntl() — whether that is because a
    # plain scalar happens to survive the register/stack mismatch or
    # because Darwin's fcntl() is implemented differently under the hood
    # is not established here. Net effect for issue #124's own framing:
    # ioctl's pointer-out-parameter form is NOT reachable directly on
    # this toolchain and needs a shim (a tiny C wrapper choosing the
    # right calling convention — same shape as the existing mjs_ctx_call
    # dispatch shim, roughly 5-10 lines) rather than a raw @extern.
    var one_byte = stack_allocation[1, Byte]()
    one_byte[0] = 7
    _ = probe_send(server, one_byte.bitcast[Byte](), 1, 0)
    var avail = stack_allocation[1, Int32]()
    avail[0] = -1
    var iocrc = probe_ioctl3(client, oracle_const_FIONREAD(), avail)
    _ = c.check(
        "ioctl(fd, FIONREAD, &n) [3-arg] direct call itself succeeds"
        " (rc == 0) — the call is reachable",
        iocrc == 0,
    )
    _ = c.check(
        "ioctl(FIONREAD)'s pointer-out-parameter write-through is NOT"
        " observed directly (DEFECT, documented above; needs a shim) —"
        " this check documents the defect rather than papering over it",
        avail[0] == -1,
    )
    var drain = stack_allocation[1, Byte]()
    _ = probe_recv(client, drain.bitcast[Byte](), 1, 0)

    _ = probe_close(client)
    _ = probe_close(server)

    # ===================================================================
    # errno — three distinct, deliberately-triggered failure modes, read
    # through the platform's REAL thread-local accessor, diffed against
    # the oracle forcing the identical failure itself.
    # ===================================================================

    # 1. EBADF: close(-1).
    var ebadf_rc = probe_close(-1)
    var ebadf_errno = read_errno()
    _ = c.check("EBADF case: close(-1) direct fails", ebadf_rc == -1)
    _ = c.check(
        "EBADF case: direct errno matches oracle_const_EBADF()",
        ebadf_errno == oracle_const_EBADF(),
    )
    var oracle_ebadf = oracle_force_ebadf()
    _ = c.check(
        "EBADF case: oracle's own close(-1) reproduces the same -errno",
        oracle_ebadf == -oracle_const_EBADF(),
    )

    # 2. EINVAL: mprotect on a misaligned address.
    var addr2 = probe_mmap(0, UInt64(page_size), prot_rw, flags_anon, -1, 0)
    var misaligned = addr2 + 1
    var einval_rc = probe_mprotect(misaligned, UInt64(page_size), oracle_const_PROT_READ())
    var einval_errno = read_errno()
    _ = c.check("EINVAL case: mprotect(misaligned) direct fails", einval_rc == -1)
    _ = c.check(
        "EINVAL case: direct errno matches oracle_const_EINVAL()",
        einval_errno == oracle_const_EINVAL(),
    )
    var oracle_einval = oracle_force_einval_mprotect(misaligned)
    _ = c.check(
        "EINVAL case: oracle's own mprotect(misaligned) reproduces the"
        " same -errno",
        oracle_einval == -oracle_const_EINVAL(),
    )
    _ = probe_munmap(addr2, UInt64(page_size))

    # 3. EAGAIN: recv on a non-blocking socket with nothing queued.
    var fd_a2 = stack_allocation[1, Int32]()
    var fd_b2 = stack_allocation[1, Int32]()
    _ = oracle_make_nonblocking_pair(fd_a2, fd_b2)
    var empty_buf = stack_allocation[1, Byte]()
    var eagain_n = probe_recv(fd_a2[0], empty_buf.bitcast[Byte](), 1, 0)
    var eagain_errno = read_errno()
    _ = c.check("EAGAIN case: recv() on empty non-blocking socket fails", eagain_n == -1)
    _ = c.check(
        "EAGAIN case: direct errno matches oracle_const_EAGAIN()",
        eagain_errno == oracle_const_EAGAIN(),
    )
    var oracle_eagain = oracle_force_eagain_recv(fd_b2[0])
    _ = c.check(
        "EAGAIN case: oracle's own recv() on its own empty non-blocking"
        " socket reproduces the same -errno",
        oracle_eagain == -oracle_const_EAGAIN(),
    )
    _ = probe_close(fd_a2[0])
    _ = probe_close(fd_b2[0])

    print("")
    if c.failures != 0:
        print("RESULT: " + String(c.failures) + " FAILED")
        raise Error(
            "libc_calls_test FAILED (" + String(c.failures) + " checks)"
        )
    print("RESULT: all green")
