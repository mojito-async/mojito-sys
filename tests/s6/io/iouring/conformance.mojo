# mojito-sys S6.6 — io_uring experimental backend conformance
# (issue #78, spec §28/§30/§27.2 + §38.7 io_uring-specific rows).
#
# Drives the §27.1 ReadinessPoller surface implemented by
# mojito_sys.io.platform.iouring.IoUringPoller over the frozen
# mjs_iouring_* C ABI (native/include/mojito_sys.h s6-ioring block;
# native/posix/mjs_iouring.c). CAPABILITY FLAG doctrine (spec §28:
# "io_uring MUST remain behind a capability/feature flag until ..."):
# the backend is usable ONLY when the host kernel supports io_uring AND
# the explicit capability flag MOJITO_IO_URING=1 is set in the
# environment. IoUringPoller.create() raises when the flag is missing OR
# the host has no io_uring backend.
#
# ROWS:
#   t8_01 capability-gate            — RUNS ON EVERY HOST: create() succeeds
#                                      IFF the backend is usable (host
#                                      support AND flag). On Darwin (or
#                                      Linux without the flag) create() MUST
#                                      raise; with flag+Linux it must not.
#   t8_02 feature-detection          — §38.7 io_uring-specific: the uring
#                                      setup probe (mjs_iouring_probe) is
#                                      exercised as a REAL behavior ONLY on
#                                      Linux; elsewhere UNSUPPORTED-PLATFORM.
#   t8_03 submission-completion rt   — §38.7 io_uring-specific: register,
#                                      write a pipe, submit, reap the CQE,
#                                      token round-trip. Linux+flag only.
#   t8_04 SQ/CQ growth               — §38.7 io_uring-specific: query the
#                                      configured SQ/CQ entry counts; grow
#                                      registrations through a batch and
#                                      confirm completions keep flowing.
#                                      Linux+flag only.
#   t8_05 common register-readable   — §38.7 common via the trait.
#   t8_06 common register-writable   — §38.7 common (immediate readiness).
#   t8_07 common timeout-no-events   — §38.7 common.
#   t8_08 common multiple-ready      — §38.7 common.
#   t8_09 common unregister          — §38.7 common (stops delivery).
#   t8_10 common token-reuse         — §38.7 common / §31 token reuse.
#   t8_11 common eof                 — §38.7 common EOF delivery.
#   t8_12 poller destruction         — §31: consume handle; double close.
#
# On hosts without an usable io_uring ring the behavior rows t8_02..t8_12
# print an EXPLICIT UNSUPPORTED-PLATFORM row (test-matrix precedent:
# tests/s5/ctx/run.sh ELF rows, §38.6-style — never a silent skip); the
# suite still compiles the full Linux behavior path and exits green with
# the explicit exclusion. Set MOJITO_IO_URING=1 on a Linux host (with
# io_uring in the kernel) to exercise the backend for real.
#
# b2 notes (matching the s6-poller precedent):
#   - Null pointers are RUNTIME zeros (`unsafe_from_address=0` literals
#     are rejected in 1.0.0b2).
#   - Diagnostics go to stdout; failures accumulate in `failed`. The
#     suite's own raise sites carry CONSTANT payloads only.
#   - Raw libc externs in THIS FILE are fixture plumbing only (pipe/
#     read/write/close/usleep) — they add no mojito-sys ABI.
#   - Trait-constrained drivers bind T to ReadinessPoller for
#     register/modify/unregister; wait/wake are exercised through the
#     same-named concrete methods (b2 SIGSEGVs generic dispatch of the
#     (Span, Optional[Duration]) mut-self signature — see readiness.mojo).

from std.ffi import c_size_t, c_uint
from std.memory import Span, UnsafePointer, stack_allocation
from std.sys import CompilationTarget

from mojito_sys.io.externs import (
    ByteBuf,
    UringPtr,
    U32Slot,
    TimeoutSlot,
    WaitCountSlot,
    probe_uring_probe,
    probe_uring_available,
)
from mojito_sys.io.handle import NativeIoHandle
from mojito_sys.io.poller import (
    EVENT_EOF,
    EVENT_ERROR,
    EVENT_READABLE,
    EVENT_WRITABLE,
    IoEvent,
    IoInterest,
)
from mojito_sys.io.platform.iouring import (
    WAIT_ERROR,
    WAIT_INTERRUPTED,
    WAIT_OK,
    IoUringPoller,
    classify_wait_rc,
)
from mojito_sys.io.readiness import ReadinessPoller
from mojito_sys.time.duration import Duration, duration_from_millis
from mojito_sys.time.monotonic import monotonic_now

# ---- host/flag parametrization ----------------------------------------------
comptime IS_DARWIN = CompilationTarget().is_macos()
comptime IS_LINUX = CompilationTarget().is_linux()


# Test-matrix platform tag for the explicit UNSUPPORTED-PLATFORM rows.
def _platform_tag() -> String:
    if IS_DARWIN:
        return "Darwin/arm64 (no io_uring on host; §38.6-style)"
    if IS_LINUX:
        return "Linux/arm64 (io_uring ring not usable: flag/host)"
    return "UNKNOWN/arm64"


def _backend_usable() -> Bool:
    # The full capability predicate exactly as the C layer defines it:
    # host kernel supports io_uring AND MOJITO_IO_URING=1 is set.
    return (probe_uring_available() != 0) and (probe_uring_probe() != 0)


# ---- pointer aliases ---------------------------------------------------------
comptime CellsPtr = UnsafePointer[Int64, MutUntrackedOrigin]
comptime AnyCellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime Int32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime IoEventPtr = UnsafePointer[IoEvent, MutAnyOrigin]
comptime BufPtr = UnsafePointer[Byte, MutAnyOrigin]

comptime POLL_CAP = 8                 # events per wait in the small fixtures
comptime EVBUF_WORDS = POLL_CAP * 2   # 16 bytes per mjs_poll_event

# ---- fixture-only libc plumbing ----------------------------------------------

@extern("pipe")
def _pipe(fds: Int32Ptr) abi("C") -> Int32:
    ...


# readv/writev (not plain read/write: the b2 stdlib shadows those symbols),
# identical semantics on pipe fixtures.
@extern("readv")
def _readv(fd: Int32, iov: BufPtr, cnt: Int32) abi("C") -> Int64:
    ...


@extern("writev")
def _writev(fd: Int32, iov: BufPtr, cnt: Int32) abi("C") -> Int64:
    ...


def _read(fd: Int32, buf: BufPtr, n: c_size_t) -> Int64:
    var iov = stack_allocation[2, Int64]()
    iov[0] = Int64(Int(buf))
    iov[1] = Int64(n)
    return _readv(fd, _bb_of(iov), 1)


def _write(fd: Int32, buf: BufPtr, n: c_size_t) -> Int64:
    var iov = stack_allocation[2, Int64]()
    iov[0] = Int64(Int(buf))
    iov[1] = Int64(n)
    return _writev(fd, _bb_of(iov), 1)


@extern("close")
def _close(fd: Int32) abi("C") -> Int32:
    ...


def _bb_of(cell: AnyCellsPtr) -> ByteBuf:
    return ByteBuf(unsafe_from_address=Int(cell))


def _bb_of_byte(p: UnsafePointer[Byte, MutAnyOrigin]) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(p))


# ---- small helpers ---------------------------------------------------------------
def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) != -1


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def _zero_cells(cell: AnyCellsPtr, words: Int):
    var i = 0
    while i < words:
        cell[i] = 0
        i += 1


def _pipe_into(fds: Int32Ptr) -> Bool:
    return _pipe(fds) == 0


def _drain_one(fd: Int32):
    var one = stack_allocation[1, Byte]()
    _ = _read(fd, _bb_of_byte(one), 1)


def _span_ptr(cell: AnyCellsPtr) -> IoEventPtr:
    return IoEventPtr(unsafe_from_address=Int(cell))


def _fresh_span(cell: AnyCellsPtr) -> Span[IoEvent, MutAnyOrigin]:
    _zero_cells(cell, EVBUF_WORDS)
    return Span[IoEvent, MutAnyOrigin](ptr=_span_ptr(cell), length=POLL_CAP)


def _deadline_ticks(budget_ms: UInt64) raises -> UInt64:
    var span = duration_from_millis(budget_ms)
    return monotonic_now().ticks + span.ns


# ---- trait-constrained drivers (§27.1 conformance proof) ------------------------
def _t_register[T: ReadinessPoller](
    mut p: T, fd: Int32, interests: IoInterest, token: UInt64
) raises:
    p.register(NativeIoHandle(fd), interests, token)


def _t_modify[T: ReadinessPoller](
    mut p: T, fd: Int32, interests: IoInterest, token: UInt64
) raises:
    p.modify(NativeIoHandle(fd), interests, token)


def _t_unregister[T: ReadinessPoller](mut p: T, fd: Int32) raises:
    p.unregister(NativeIoHandle(fd))


# COMPILE-TIME trait-conformance witness (same doc as the poller lane).
def _trait_witness[T: ReadinessPoller](p: T) -> Bool:
    return True


# An explicit, counted UNSUPPORTED-PLATFORM row (never a silent skip).
def _unsupported(name: String) -> Bool:
    print(name + ": UNSUPPORTED-PLATFORM (" + _platform_tag() + ")")
    return True  # an exclusion that does NOT fail the suite


# ---- behavior rows (Linux + flag only) -----------------------------------------

# t8_03: register a pipe reader, write a byte, wait -> token round trip.
def _run_roundtrip(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0x6000DEADC0DE0000))
    var b = stack_allocation[1, Byte]()
    b[0] = Byte(0x55)
    _ = _write(fds[1], _bb_of_byte(b), 1)
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    var ok = n == 1
    if ok:
        ok = (
            span[0].fd == fds[0]
            and (span[0].events & EVENT_READABLE) != 0
            and span[0].token == UInt64(0x6000DEADC0DE0000)
        )
    _t_unregister(p, fds[0])
    _drain_one(fds[0])
    _ = _close(fds[0])
    _ = _close(fds[1])
    return ok


# t8_04: query SQ/CQ entry counts; grow through a batch of registrations
# and confirm completions keep flowing (SQ/CQ growth, §38.7 io_uring).
def _run_growth(mut p: IoUringPoller) -> Bool:
    var sqc = stack_allocation[1, UInt32]()
    var cqc = stack_allocation[1, UInt32]()
    if p.entries(sqc, cqc) != 0:
        return False
    var sq = sqc[]
    var cq = cqc[]
    if sq == 0 or cq == 0:
        return False
    # Grow submitted op count stepwise (1, 2, 4, ... up to 32) and confirm
    # each step's writers surface in a wait.
    var n = 1
    var ok = True
    while n <= 32 and ok:
        var pairs = stack_allocation[64, Int32]()
        var i = 0
        while i < n:
            if not _pipe_into(Int32Ptr(unsafe_from_address=Int(pairs) + 8 * i)):
                ok = False
                break
            _t_register(
                p, Int32Ptr(unsafe_from_address=Int(pairs) + 8 * i)[0],
                IoInterest.READABLE, UInt64(0x70000000 + i),
            )
            i += 1
        if not ok:
            break
        var b = stack_allocation[1, Byte]()
        b[0] = Byte(0x11)
        var w = 0
        while w < n:
            _ = _write(
                Int32Ptr(unsafe_from_address=Int(pairs) + 8 * w)[1],
                _bb_of_byte(b), 1,
            )
            w += 1
        var evcell = stack_allocation[EVBUF_WORDS, Int64]()
        var got = 0
        var dl = _deadline_ticks(UInt64(2000))
        while got < n and monotonic_now().ticks < dl:
            var span = _fresh_span(evcell)
            var nn = p.wait(span, Optional[Duration](duration_from_millis(UInt64(200))))
            got += nn
        if got < n:
            ok = False
        var u = 0
        while u < n:
            _t_unregister(
                p, Int32Ptr(unsafe_from_address=Int(pairs) + 8 * u)[0]
            )
            _drain_one(Int32Ptr(unsafe_from_address=Int(pairs) + 8 * u)[0])
            _ = _close(Int32Ptr(unsafe_from_address=Int(pairs) + 8 * u)[0])
            _ = _close(Int32Ptr(unsafe_from_address=Int(pairs) + 8 * u)[1])
            u += 1
        n *= 2
    return ok


# t8_05-t8_11 common poller cases (Linux + flag only).
def _run_register_writable(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    _t_register(p, fds[1], IoInterest.WRITABLE, UInt64(0x2222))
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    var ok = n == 1
    if ok:
        ok = (
            span[0].fd == fds[1]
            and (span[0].events & EVENT_WRITABLE) != 0
            and span[0].token == UInt64(0x2222)
        )
    _t_unregister(p, fds[1])
    _ = _close(fds[0])
    _ = _close(fds[1])
    return ok


def _run_timeout(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0x3333))
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(5))))
    _t_unregister(p, fds[0])
    _ = _close(fds[0])
    _ = _close(fds[1])
    return n == 0


def _run_multiple(mut p: IoUringPoller) -> Bool:
    var pa = stack_allocation[2, Int32]()
    var pb = stack_allocation[2, Int32]()
    if (not _pipe_into(pa)) or (not _pipe_into(pb)):
        return False
    _t_register(p, pa[0], IoInterest.READABLE, UInt64(0xAAAA1))
    _t_register(p, pb[0], IoInterest.READABLE, UInt64(0xBBBB2))
    var b = stack_allocation[1, Byte]()
    b[0] = Byte(1)
    _ = _write(pa[1], _bb_of_byte(b), 1)
    _ = _write(pb[1], _bb_of_byte(b), 1)
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    var saw_a = False
    var saw_b = False
    var k = 0
    while k < n:
        if span[k].token == UInt64(0xAAAA1):
            saw_a = True
        if span[k].token == UInt64(0xBBBB2):
            saw_b = True
        k += 1
    var ok = (n >= 2) and saw_a and saw_b
    _t_unregister(p, pa[0])
    _t_unregister(p, pb[0])
    _drain_one(pa[0])
    _drain_one(pb[0])
    _ = _close(pa[0])
    _ = _close(pa[1])
    _ = _close(pb[0])
    _ = _close(pb[1])
    return ok


def _run_unregister(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    var b = stack_allocation[1, Byte]()
    b[0] = Byte(9)
    _ = _write(fds[1], _bb_of_byte(b), 1)  # pending BEFORE register
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0x5555))
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n1 = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    _t_unregister(p, fds[0])
    _drain_one(fds[0])
    var span2 = _fresh_span(evcell)
    var n2 = p.wait(span2, Optional[Duration](duration_from_millis(UInt64(20))))
    _ = _close(fds[0])
    _ = _close(fds[1])
    return (n1 == 1) and (n2 == 0)


def _run_token_reuse(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0xA000))
    _t_unregister(p, fds[0])
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0xB000))
    var b = stack_allocation[1, Byte]()
    b[0] = Byte(10)
    _ = _write(fds[1], _bb_of_byte(b), 1)
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    var ok = n >= 1 and span[0].token == UInt64(0xB000)
    _t_unregister(p, fds[0])
    _drain_one(fds[0])
    _ = _close(fds[0])
    _ = _close(fds[1])
    return ok


def _run_eof(mut p: IoUringPoller) -> Bool:
    var fds = stack_allocation[2, Int32]()
    if not _pipe_into(fds):
        return False
    _t_register(p, fds[0], IoInterest.READABLE, UInt64(0xC000))
    _ = _close(fds[1])  # writer gone: reader reports EOF
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()
    var span = _fresh_span(evcell)
    var n = p.wait(span, Optional[Duration](duration_from_millis(UInt64(1000))))
    var ok = n == 1
    if ok:
        ok = (
            (span[0].events & EVENT_READABLE) != 0
            and (span[0].events & EVENT_EOF) != 0
            and span[0].token == UInt64(0xC000)
        )
    _t_unregister(p, fds[0])
    _ = _close(fds[0])
    return ok


def main() raises:
    var failed = 0

    # ================= t8_01 capability-gate (RUNS EVERYWHERE) ==============
    # The gate ALWAYS holds: create() succeeds IFF the backend is usable
    # (host io_uring support AND MOJITO_IO_URING=1). On Darwin (or Linux
    # without the flag) create() MUST raise an explicit error; with
    # flag+Linux it must succeed.
    var avail = _backend_usable()
    var created = True
    try:
        var p = IoUringPoller.create()
        p.close()
    except:
        created = False
    var gate_ok = (avail and created) or ((not avail) and (not created))
    if not check("t8_01 capability-gate(flag+host gated)", gate_ok):
        failed += 1

    # If the backend is not usable on this host, the rest is explicit
    # UNSUPPORTED-PLATFORM rows. The trait witness still binds below.
    var usable = avail
    var poller = IoUringPoller()
    if usable:
        poller = IoUringPoller.create()
    if not check("t8_00 trait-conformance-witness", _trait_witness(poller)):
        failed += 1
    if not usable:
        # All remaining rows are explicit exclusions (never silent skips).
        var rows = [
            "t8_02 feature-detection(uring-setup probe)",
            "t8_03 submission-completion round-trip",
            "t8_04 SQ/CQ growth",
            "t8_05 common register-readable",
            "t8_06 common register-writable",
            "t8_07 common timeout-no-events",
            "t8_08 common multiple-ready",
            "t8_09 common unregister",
            "t8_10 common token-reuse",
            "t8_11 common eof",
            "t8_12 poller destruction",
        ]
        var ri = 0
        while ri < len(rows):
            if not _unsupported(rows[ri]):
                failed += 1
            ri += 1
        print("")
        if failed == 0:
            print("RESULT: all green")
        else:
            print("RESULT: FAILED (" + String(failed) + " checks)")
        return

    # ---- usable backend: run the real rows. ---------------------------------
    var evcell = stack_allocation[EVBUF_WORDS, Int64]()

    # ================= t8_02 feature detection ==============================
    var det_ok = probe_uring_probe() != 0
    if not check("t8_02 feature-detection(uring-setup probe)", det_ok):
        failed += 1

    # ================= t8_03 submission/completion round trip ===============
    var rt_ok = True
    try:
        rt_ok = _run_roundtrip(poller)
    except:
        rt_ok = False
    if not check("t8_03 submission-completion round-trip", rt_ok):
        failed += 1

    # ================= t8_04 SQ/CQ growth ===================================
    var gr_ok = True
    try:
        gr_ok = _run_growth(poller)
    except:
        gr_ok = False
    if not check("t8_04 SQ/CQ growth", gr_ok):
        failed += 1

    # ================= t8_05-t8_12 common cases =============================
    var c5 = True
    try:
        var fds5 = stack_allocation[2, Int32]()
        c5 = _pipe_into(fds5)
        _t_register(poller, fds5[0], IoInterest.READABLE, UInt64(0xDEADBEEFCAFEB000))
        var b5 = stack_allocation[1, Byte]()
        b5[0] = Byte(0x41)
        _ = _write(fds5[1], _bb_of_byte(b5), 1)
        var span5 = _fresh_span(evcell)
        var n5 = poller.wait(span5, Optional[Duration](duration_from_millis(UInt64(1000))))
        c5 = c5 and (n5 == 1)
        if c5:
            c5 = (
                span5[0].fd == fds5[0]
                and (span5[0].events & EVENT_READABLE) != 0
                and span5[0].token == UInt64(0xDEADBEEFCAFEB000)
            )
        _t_unregister(poller, fds5[0])
        _drain_one(fds5[0])
        _ = _close(fds5[0])
        _ = _close(fds5[1])
    except:
        c5 = False
    if not check("t8_05 common register-readable(token-round-trip)", c5):
        failed += 1

    var c6 = True
    try:
        c6 = _run_register_writable(poller)
    except:
        c6 = False
    if not check("t8_06 common register-writable(immediate)", c6):
        failed += 1

    var c7 = True
    try:
        c7 = _run_timeout(poller)
    except:
        c7 = False
    if not check("t8_07 common timeout-no-events(5ms)", c7):
        failed += 1

    var c8 = True
    try:
        c8 = _run_multiple(poller)
    except:
        c8 = False
    if not check("t8_08 common multiple-ready-handles", c8):
        failed += 1

    var c9 = True
    try:
        c9 = _run_unregister(poller)
    except:
        c9 = False
    if not check("t8_09 common unregister(stops-delivery)", c9):
        failed += 1

    var c10 = True
    try:
        c10 = _run_token_reuse(poller)
    except:
        c10 = False
    if not check("t8_10 common token-reuse(new-token-only)", c10):
        failed += 1

    var c11 = True
    try:
        c11 = _run_eof(poller)
    except:
        c11 = False
    if not check("t8_11 common eof(readable|eof-once)", c11):
        failed += 1

    # ================= t8_12 poller destruction =============================
    poller.close()
    var destroy_ok = True
    try:
        poller.wake()
        destroy_ok = False  # use-after-close MUST raise
    except e:
        destroy_ok = destroy_ok and contains(String(e), "EINVAL")
    try:
        poller.close()
        destroy_ok = False  # double close MUST raise
    except e:
        destroy_ok = destroy_ok and contains(String(e), "EINVAL")
    if not check("t8_12 poller destruction(consume+double-close-einval)", destroy_ok):
        failed += 1

    print("")
    if failed == 0:
        print("RESULT: all green")
    else:
        print("RESULT: FAILED (" + String(failed) + " checks)")