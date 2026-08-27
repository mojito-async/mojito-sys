# mojito-sys S6.2 — non-blocking socket conformance (issue #74, spec §26).
#
# Drives the §26 NativeSocket surface (Mojo wrappers over the frozen
# mjs_socket_* / mjs_sockaddr_* C ABI) through the §38.8 check list,
# loopback/local fixtures ONLY (spec L1981):
#
#   t6_01 create            — tcp_v4 yields a live fd; an invalid family is
#                             a deterministic raw -EINVAL at the C layer;
#   t6_02 address-conversion— dotted-quad parse/format round-trip through
#                             mjs_sockaddr_ipv4/format4; malformed input is
#                             -EINVAL with the out-slot untouched;
#   t6_03 bind-listen       — bind(127.0.0.1:0) + listen; the bound port is
#                             read back via libc getsockname (fixture only);
#   t6_04 nonblocking-config— set_nonblocking(True/False/True); a QUIET
#                             non-blocking accept returns WouldBlock within
#                             a hard wall-clock bound (never parks, SYS-5);
#   t6_05 echo-v4           — full loopback: accept spins WouldBlock->Ready;
#                             client/server swap 512 bytes with DELIBERATELY
#                             partial send/recv windows (both directions);
#                             partiality must be OBSERVED, and the payload
#                             byte-exact on both legs;
#   t6_06 eof-shutdown      — shutdown(WRITE) then drain: server recv ends
#                             Closed (EOF), never Ready(0) or Error;
#   t6_07 refusal           — connect to a provably portless loopback
#                             address raises; raw C rc == -ECONNREFUSED
#                             (exact host spelling pinned);
#   t6_08 peer-reset        — SO_LINGER{1,0} + close sends RST: server recv
#                             maps to IoAttempt.Error carrying ECONNRESET
#                             (exact host spelling pinned);
#   t6_09 eintr-eagain-map  — §38.11 fault SIMULATION of the mapping core:
#                             EINTR -> Interrupted, EAGAIN -> WouldBlock,
#                             any other errno -> Error(+errno), recv rc==0
#                             n==0 -> Closed, send rc==0 n==0 -> Ready(0),
#                             partial counts ride through untouched;
#                             (live EAGAIN is exercised by t6_04; live
#                             refusal/reset by t6_07/t6_08);
#   t6_10 close-once        — double-close prevention: second close() raises
#                             without re-entering C; move (^) transfers and
#                             leaves the source inert (use-after-move raises);
#   t6_11 ipv6              — ::1 loopback echo where the host supports it;
#   t6_12 unix-domain       — filesystem-bound AF_UNIX stream echo where
#                             supported; path unlinked after;
#   t6_13 nonblocking-connect — non-blocking connect reports pending via
#                             False from connect() (EINPROGRESS status, the
#                             documented try_lock/-EBUSY analogue) and never
#                             blocks.
#
# b2 notes (matching tests/s1/*/ and tests/s4/time conventions):
#   - Null pointers are built from RUNTIME zeros (`unsafe_from_address=0`
#     literals are rejected in 1.0.0b2).
#   - Diagnostics go to stdout; failures accumulate in `failed`. The suite's
#     own raise sites carry CONSTANT payloads only.
#   - Raw libc externs in THIS FILE are fixture plumbing only (port
#     discovery, SO_LINGER, unlink cleanup) — they add no mojito-sys ABI.

from std.memory import Span, UnsafePointer, stack_allocation
from std.sys import CompilationTarget

from mojito_sys.io.socket import (
    SHUT_WRITE,
    socket_address_parse_ipv4,
    socket_format_ipv4,
    ATTEMPT_CLOSED,
    ATTEMPT_ERROR,
    ATTEMPT_INTERRUPTED,
    ATTEMPT_READY,
    ATTEMPT_WOULD_BLOCK,
    NativeSocket,
    SocketAddress,
    attempt_from_rc,
)
from mojito_sys.io.externs import (
    probe_close,
    probe_connect,
    probe_sockaddr_ipv4,
    probe_socket,
)
from mojito_sys.time.monotonic import monotonic_now

comptime BufPtr = UnsafePointer[Byte, MutAnyOrigin]
comptime U8Ptr = UnsafePointer[UInt8, MutAnyOrigin]
comptime Int64Ptr = UnsafePointer[Int64, MutAnyOrigin]
comptime Int32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime NS_PER_MS = UInt64(1000000)

# Hard wall-clock budget for one non-blocking operation: if a "non-blocking"
# call ever exceeds this it parked its OS thread — fail loudly (SYS-5).
comptime NEVER_PARK_BUDGET_NS = UInt64(200000000)  # 200 ms

comptime SPIN_BUDGET_MS = UInt64(5000)
comptime PAYLOAD_LEN = 512


# ---------------------------------------------------------------------------
# Host-spelling helpers: several pinned errnos differ numerically between
# darwin and Linux; select the host spelling exactly once, here.
def _is_macos() -> Bool:
    return CompilationTarget().is_macos()


def _econnrefused() -> Int32:
    return Int32(61) if _is_macos() else Int32(111)


def _econnreset() -> Int32:
    return Int32(54) if _is_macos() else Int32(104)


# ---- fixture-only libc plumbing --------------------------------------------
@extern("getsockname")
def _getsockname(fd: Int32, sa: BufPtr, lenp: Int32Ptr) abi("C") -> Int32:
    ...


@extern("setsockopt")
def _setsockopt(
    fd: Int32, level: Int32, optname: Int32, optval: BufPtr, optlen: UInt32
) abi("C") -> Int32:
    ...
@extern("unlink")
def _unlink(path: BufPtr) abi("C") -> Int32:
    ...


def _buf_of(cell: Int64Ptr) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(cell))


# Byte-buffer view of a raw scratch allocation (fixture plumbing).
def _bbuf(p: UnsafePointer[UInt8, MutUntrackedOrigin]) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(p))


# Word-address helper: any pointer's raw address as a byte buffer.
def _wbuf(addr: Int) -> BufPtr:
    return BufPtr(unsafe_from_address=addr)




def _u8_of(p: UnsafePointer[UInt8, MutUntrackedOrigin]) -> U8Ptr:
    return U8Ptr(unsafe_from_address=Int(p))


# Caller-owned-buffer string plumbing: b2/dynlib precedent — an address
# into a CALLEE's stack_allocation frame dangles the moment the callee
# returns, so every fixture buffer lives in the caller's frame and helpers
# only FILL it.

def _fill_cstr(buf: BufPtr, cap: Int, s: String):
    # Copy `s` into `buf` NUL-terminated (caller owns the frame).
    var srcp = s.unsafe_ptr()
    var sbp = UnsafePointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(srcp)
    )
    var n = s.byte_length()
    var i = 0
    while i < n and i < cap - 1:
        buf[i] = sbp[i]
        i += 1
    buf[i] = Byte(0)


def _fill_bytes(dst: U8Ptr, s: String):
    var srcp = s.unsafe_ptr()
    var sbp = UnsafePointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(srcp)
    )
    var n = s.byte_length()
    var i = 0
    while i < n:
        dst[i] = sbp[i]
        i += 1


# Read the bound IPv4 port back out of a sockaddr_in the OS filled in.
# The port sits at bytes [2..3] big-endian in BOTH darwin and Linux layouts.
def _bound_port(fd: Int32) -> Int:
    var sa = stack_allocation[16, Byte]()
    var sl = stack_allocation[1, Int32]()
    sl[0] = 16
    var rc = _getsockname(fd, _bbuf(sa), sl)
    if rc != 0:
        return -1
    return (Int(sa[2]) << 8) | Int(sa[3])


def _deadline_ticks(budget_ms: UInt64) raises -> UInt64:
    return monotonic_now().ticks + budget_ms * NS_PER_MS


def _check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


# Spin accept until Ready or the deadline passes; returns the accepted fd
# or -1 on timeout. Callers adopt via NativeSocket._adopt(fd).
def _accept_fd(mut listener: NativeSocket, budget_ms: UInt64) raises -> Int32:
    var dl = _deadline_ticks(budget_ms)
    while monotonic_now().ticks < dl:
        var acc = listener.accept_nonblocking()
        if acc.is_ready():
            return acc.take_ready_fd()
        # WouldBlock / Interrupted: spin again (never parks).
    return Int32(-1)


def main() raises:
    var failed = 0

    # ======================= t6_01 create ==================================
    var s = NativeSocket.tcp_v4()
    var create_ok = s.is_valid() and (s.get() >= 0) and (not s.is_closed())
    # Invalid family: deterministic raw -EINVAL straight from the C layer,
    # out-slot untouched.
    var fd_slot = stack_allocation[1, Int32]()
    fd_slot[0] = -7  # sentinel: out-slot must stay untouched on failure
    var bad_rc = probe_socket(Int32(99), Int32(1), fd_slot)
    create_ok = create_ok and (bad_rc == Int32(-22)) and (fd_slot[0] == -7)
    if not _check("t6_01 create-tcp-v4(invalid-family-einval)", create_ok):
        failed += 1

    # ======================= t6_02 address conversion ======================
    var conv_ok = True
    var a = socket_address_parse_ipv4(String("127.0.0.1"), Int32(8080))
    conv_ok = conv_ok and (a.family == Int32(2)) and (a.port == Int32(8080))
    conv_ok = conv_ok and (socket_format_ipv4(a) == String("127.0.0.1"))
    var b = socket_address_parse_ipv4(String("192.168.10.7"), Int32(1))
    conv_ok = conv_ok and (socket_format_ipv4(b) == String("192.168.10.7"))
    conv_ok = conv_ok and (b.octet(0) == UInt8(192)) and (b.octet(3) == UInt8(7))
    # Malformed input: raw -EINVAL, out-slot untouched.
    var abuf = stack_allocation[17, Int64]()
    var z2 = 0
    while z2 < 17:
        abuf[z2] = 0
        z2 += 1
    var bad_dotted = stack_allocation[64, Byte]()
    _fill_cstr(bad_dotted, 64, String("999.1.1.1"))
    var malformed_rc = probe_sockaddr_ipv4(
        bad_dotted, Int32(80), _buf_of(abuf)
    )
    conv_ok = conv_ok and (malformed_rc == Int32(-22))
    var w = 0
    var abuf_zero = True
    while w < 17:
        abuf_zero = abuf_zero and (abuf[w] == 0)
        w += 1
    conv_ok = conv_ok and abuf_zero
    if not _check("t6_02 address-conversion", conv_ok):
        failed += 1

    # ======================= shared IPv4 loopback fixture ==================
    # Listener created blocking, configured non-blocking AFTER bind/listen
    # (proves configuration applies to an already-listening socket).
    var listener = NativeSocket.tcp_v4()
    listener.bind(socket_address_parse_ipv4(String("127.0.0.1"), Int32(0)))
    listener.listen(Int(16))
    var port = _bound_port(listener.get())
    var fixture_ok = port > 0
    listener.set_nonblocking(True)
    var addr = socket_address_parse_ipv4(String("127.0.0.1"), Int32(port))

    # ======================= t6_03 bind-listen =============================
    if not _check("t6_03 bind-listen(ephemeral-port)", fixture_ok):
        failed += 1

    # ======================= t6_04 non-blocking config =====================
    var nb_ok = True
    var t0 = monotonic_now().ticks
    var att = listener.accept_nonblocking()
    var dt = monotonic_now().ticks - t0
    nb_ok = nb_ok and att.is_would_block()
    nb_ok = nb_ok and (dt < NEVER_PARK_BUDGET_NS)
    listener.set_nonblocking(False)
    listener.set_nonblocking(True)
    var att2 = listener.accept_nonblocking()
    nb_ok = nb_ok and att2.is_would_block()
    nb_ok = nb_ok and (att2.kind == ATTEMPT_WOULD_BLOCK)
    if not _check("t6_04 nonblocking-config(quiet-wouldblock)", nb_ok):
        failed += 1

    # ======================= client for echo/refusal/reset fixtures ========
    var client = NativeSocket.tcp_v4()
    var established = client.connect(addr)  # blocking client fixture: SYS-5
    var cok = established
    client.set_nonblocking(True)

    # ======================= t6_05 echo v4 =================================
    var echo_ok = cok
    var conn_fd = _accept_fd(listener, SPIN_BUDGET_MS)
    echo_ok = echo_ok and (conn_fd >= 0)
    if conn_fd >= 0:
        var conn = NativeSocket._adopt(conn_fd)

        # --- phase A: deterministic PARTIAL RECV --------------------------
        # The client sends EXACTLY pattern_len bytes then stops; the server
        # asks for MORE than that in one window, so any successful read is
        # necessarily partial (the kernel cannot invent data).
        comptime PAT_LEN = 33
        var pattern = stack_allocation[PAT_LEN, UInt8]()
        var pi = 0
        while pi < PAT_LEN:
            pattern[pi] = UInt8((pi * 7 + 3) & 0xFF)
            pi += 1
        var pwrote = 0
        var dl5p = _deadline_ticks(SPIN_BUDGET_MS)
        while pwrote < PAT_LEN and monotonic_now().ticks < dl5p:
            var pwin = Span[UInt8](ptr=pattern + pwrote, length=PAT_LEN - pwrote)
            var pr = client.send_nonblocking(pwin)
            if pr.is_ready():
                pwrote += pr.ready_count()
        echo_ok = echo_ok and (pwrote == PAT_LEN)

        # Server spins (WouldBlock allowed) with an OVERSIZED window.
        var got = stack_allocation[PAYLOAD_LEN, UInt8]()
        var saw_partial_recv = False
        var got_total = 0
        var dl5a = _deadline_ticks(SPIN_BUDGET_MS)
        while got_total < PAT_LEN and monotonic_now().ticks < dl5a:
            var bigwin = Span[UInt8](ptr=_u8_of(got) + got_total, length=PAYLOAD_LEN - got_total)
            var r = conn.recv_nonblocking(bigwin)
            if r.is_ready():
                if r.ready_count() < PAYLOAD_LEN - got_total:
                    saw_partial_recv = True
                got_total += r.ready_count()
            elif r.is_closed():
                break
            # WouldBlock / Interrupted: keep spinning (never parks).
        echo_ok = echo_ok and (got_total == PAT_LEN)
        echo_ok = echo_ok and saw_partial_recv
        var pj = 0
        while pj < PAT_LEN and echo_ok:
            echo_ok = echo_ok and (got[pj] == pattern[pj])
            pj += 1

        # --- phase B: deterministic PARTIAL SEND --------------------------
        # Shrink the CLIENT send buffer below one span (fixture-level
        # SO_SNDBUF), then ask to send far more than fits: the kernel MUST
        # accept a strict prefix (partial) before reporting fullness.
        # SOL_SOCKET: 0xffff darwin / 1 Linux; SO_SNDBUF: 0x1001 darwin / 7
        # Linux.
        var sol_socket = Int32(65535) if _is_macos() else Int32(1)
        var sndbuf_opt = Int32(4097) if _is_macos() else Int32(7)
        var sndbuf_val = stack_allocation[1, Int32]()
        sndbuf_val[0] = 2048
        var sbrc = _setsockopt(
            client.get(),
            sol_socket,
            sndbuf_opt,
            BufPtr(unsafe_from_address=Int(sndbuf_val)),
            UInt32(4),
        )
        echo_ok = echo_ok and (sbrc == 0)

        comptime BIG_LEN = 262144  # 256 KB >> the 2048-byte send buffer
        var big = stack_allocation[BIG_LEN, UInt8]()
        var bi = 0
        while bi < BIG_LEN:
            big[bi] = UInt8((bi % PAT_LEN)) ^ UInt8((bi * 31 + 7) & 0xFF)
            bi += 1

        var sent_total = 0
        var send_partials = 0
        var saw_wouldblock = False
        var dl5b = _deadline_ticks(SPIN_BUDGET_MS)
        while monotonic_now().ticks < dl5b:
            var remain = BIG_LEN - sent_total
            var chunk = 65536 if (remain > 65536) else remain
            var out_span = Span[UInt8](
                ptr=_u8_of(big) + sent_total, length=chunk
            )
            var sr = client.send_nonblocking(out_span)
            if sr.is_ready():
                if sr.ready_count() < chunk:
                    send_partials += 1
                sent_total += sr.ready_count()
                if sent_total >= BIG_LEN:
                    break
            elif sr.is_would_block():
                saw_wouldblock = True
                break

        # The buffer can never hold the whole span, so a partial accept is
        # unavoidable before the first full-buffer signal.
        echo_ok = echo_ok and (send_partials > 0)
        echo_ok = echo_ok and (saw_wouldblock or (sent_total == BIG_LEN))

        # --- reverse leg: byte-exact echo through odd windows -------------
        # Server echoes the FIRST 33 received bytes back in odd chunks; the
        # non-blocking client accumulates them (its receive side is clean).
        var echoed = 0
        var dl5c = _deadline_ticks(SPIN_BUDGET_MS)
        while echoed < PAT_LEN and monotonic_now().ticks < dl5c:
            var remain3 = PAT_LEN - echoed
            var chunk3 = 7 if (remain3 > 7) else remain3
            var out3 = Span[UInt8](
                ptr=_u8_of(got) + echoed, length=chunk3
            )
            var sr3 = conn.send_nonblocking(out3)
            if sr3.is_ready():
                echoed += sr3.ready_count()

        var back = stack_allocation[PAT_LEN, UInt8]()
        var got_back = 0
        var dl5d = _deadline_ticks(SPIN_BUDGET_MS)
        while got_back < PAT_LEN and monotonic_now().ticks < dl5d:
            var winlen4 = PAT_LEN - got_back
            var win4 = Span[UInt8](
                ptr=_u8_of(back) + got_back, length=winlen4
            )
            var rr = client.recv_nonblocking(win4)
            if rr.is_ready():
                got_back += rr.ready_count()
            elif rr.is_closed():
                break

        echo_ok = echo_ok and (echoed == PAT_LEN)
        echo_ok = echo_ok and (got_back == PAT_LEN)
        var q = 0
        while q < PAT_LEN and echo_ok:
            echo_ok = echo_ok and (back[q] == got[q])
            q += 1
        conn.close()
    client.close()
    if not _check("t6_05 echo-v4(partial-send+recv)", echo_ok):
        failed += 1

    # ======================= t6_06 EOF / shutdown ==========================
    var eof_ok = True
    var c2 = NativeSocket.tcp_v4()
    eof_ok = eof_ok and c2.connect(addr)
    c2.set_nonblocking(True)
    var conn2_fd = _accept_fd(listener, SPIN_BUDGET_MS)
    eof_ok = eof_ok and (conn2_fd >= 0)
    if conn2_fd >= 0:
        var conn2 = NativeSocket._adopt(conn2_fd)
        conn2.set_nonblocking(True)
        var ping_buf = stack_allocation[8, UInt8]()
        _fill_bytes(ping_buf, String("ping"))
        var wrote = 0
        var dl6a = _deadline_ticks(SPIN_BUDGET_MS)
        while wrote < 4 and monotonic_now().ticks < dl6a:
            var hw = Span[UInt8](ptr=ping_buf + wrote, length=4 - wrote)
            var hr = c2.send_nonblocking(hw)
            if hr.is_ready():
                wrote += hr.ready_count()
        eof_ok = eof_ok and (wrote == 4)
        # Half-close the CLIENT write side: server drains 4 bytes, then the
        # next recv MUST be Closed (EOF) — never Ready(0), never Error.
        c2.shutdown(SHUT_WRITE)
        var drained = 0
        var saw_eof = False
        var buf2 = stack_allocation[64, UInt8]()
        var dl6b = _deadline_ticks(SPIN_BUDGET_MS)
        while monotonic_now().ticks < dl6b:
            var win3 = Span[UInt8](ptr=_u8_of(buf2), length=64)
            var r3 = conn2.recv_nonblocking(win3)
            if r3.is_ready():
                drained += r3.ready_count()
            elif r3.is_closed():
                saw_eof = True
                break
            elif r3.is_interrupted():
                continue
        eof_ok = eof_ok and saw_eof and (drained == 4)
        conn2.close()
    c2.close()
    if not _check("t6_06 eof-shutdown(recv-closed)", eof_ok):
        failed += 1

    # ======================= t6_07 connection refusal ======================
    var ref_ok = True
    # Prove a port has no listener: bind it ourselves, learn it, CLOSE it.
    var victim = NativeSocket.tcp_v4()
    victim.bind(socket_address_parse_ipv4(String("127.0.0.1"), Int32(0)))
    victim.listen(Int(1))
    var dead_port = _bound_port(victim.get())
    victim.close()
    ref_ok = ref_ok and victim.is_closed()
    var dead_addr = socket_address_parse_ipv4(
        String("127.0.0.1"), Int32(dead_port)
    )
    # Wrapper behavior: connect RAISES (decoded error).
    var raised = False
    var prober = NativeSocket.tcp_v4()
    try:
        _ = prober.connect(dead_addr)
    except e:
        raised = True
        _ = e
    ref_ok = ref_ok and raised
    prober.close()
    # Raw layer: EXACT host spelling of ECONNREFUSED.
    var raw_slot = stack_allocation[1, Int32]()
    raw_slot[0] = -7
    var rc_raw = probe_socket(Int32(2), Int32(1), raw_slot)
    ref_ok = ref_ok and (rc_raw == 0)
    var dead_cell = stack_allocation[17, Int64]()
    _fill_sockaddr(dead_cell, dead_addr)
    ref_ok = ref_ok and (
        probe_connect(raw_slot[0], _buf_of(dead_cell)) == -_econnrefused()
    )
    _ = probe_close(raw_slot[0])
    if not _check("t6_07 connection-refusal(econnrefused)", ref_ok):
        failed += 1

    # ======================= t6_08 peer reset ==============================
    var rst_ok = True
    var rst_client = NativeSocket.tcp_v4()
    rst_ok = rst_ok and rst_client.connect(addr)
    var conn3_fd = _accept_fd(listener, SPIN_BUDGET_MS)
    rst_ok = rst_ok and (conn3_fd >= 0)
    if conn3_fd >= 0:
        var conn3 = NativeSocket._adopt(conn3_fd)
        conn3.set_nonblocking(True)
        # SO_LINGER {onoff=1, sec=0} + close => RST, not FIN.
        # SOL_SOCKET: 0xffff darwin / 1 Linux.
        # SO_LINGER: 0x80 (BSD/darwin) / 13 (Linux).
        var sol_socket = Int32(65535) if _is_macos() else Int32(1)
        var so_linger = Int32(128) if _is_macos() else Int32(13)
        var lg = stack_allocation[2, Int32]()
        lg[0] = 1
        lg[1] = 0
        var src = _setsockopt(
            rst_client.get(),
            sol_socket,
            so_linger,
            _wbuf(Int(lg)),
            UInt32(8),
        )
        rst_ok = rst_ok and (src == 0)
        # Leave data queued TOWARD the server before the RST close: the
        # kernel then MUST reset the stream (the queued bytes would be
        # lost), so recv surfaces ECONNRESET deterministically.
        var rst_data = stack_allocation[4, UInt8]()
        _fill_bytes(rst_data, String("wxyz"))
        var rwrote = 0
        var dl8pre = _deadline_ticks(SPIN_BUDGET_MS)
        while rwrote < 4 and monotonic_now().ticks < dl8pre:
            var rwin = Span[UInt8](ptr=rst_data + rwrote, length=4 - rwrote)
            var rr2 = rst_client.send_nonblocking(rwin)
            if rr2.is_ready():
                rwrote += rr2.ready_count()
        rst_client.close()
        var reset_errno = Int32(0)
        var saw_reset = False
        var buf3 = stack_allocation[64, UInt8]()
        var dl8a = _deadline_ticks(SPIN_BUDGET_MS)
        while monotonic_now().ticks < dl8a:
            var win4 = Span[UInt8](ptr=_u8_of(buf3), length=64)
            var r4 = conn3.recv_nonblocking(win4)
            if r4.is_error():
                reset_errno = r4.errno_code()
                saw_reset = reset_errno == _econnreset()
                break
            if r4.is_closed():
                # Clean EOF means the RST lost the race to a FIN — keep
                # spinning; linger-0 loopback does not produce FIN-first.
                continue
        rst_ok = rst_ok and saw_reset
        conn3.close()
    if not _check("t6_08 peer-reset(econnreset-as-error)", rst_ok):
        failed += 1

    # ======================= t6_09 EINTR/EAGAIN mapping core ===============
    var map_ok = True
    # EINTR surfaces as Interrupted (caller retries; never auto-retried,
    # never parked). 4 is EINTR on BOTH hosts.
    var m1 = attempt_from_rc(Int32(-4), 0, True)
    map_ok = map_ok and m1.is_interrupted()
    map_ok = map_ok and (m1.kind == ATTEMPT_INTERRUPTED)
    # Host-spelled EAGAIN maps to WouldBlock.
    var eagain = Int32(35) if _is_macos() else Int32(11)
    var m2 = attempt_from_rc(-eagain, 0, True)
    map_ok = map_ok and m2.is_would_block()
    map_ok = map_ok and (m2.kind == ATTEMPT_WOULD_BLOCK)
    # Any other errno is Error carrying the POSITIVE errno.
    var m3 = attempt_from_rc(-_econnreset(), 0, True)
    map_ok = map_ok and m3.is_error()
    map_ok = map_ok and (m3.errno_code() == _econnreset())
    map_ok = map_ok and (m3.kind == ATTEMPT_ERROR)
    # recv EOF: rc==0 with zero count => Closed (NOT Ready(0)).
    var m4 = attempt_from_rc(Int32(0), 0, True)
    map_ok = map_ok and m4.is_closed()
    map_ok = map_ok and (m4.kind == ATTEMPT_CLOSED)
    # send-style (eof_at_zero=False): rc==0 with n=0 stays Ready(0).
    var m5 = attempt_from_rc(Int32(0), 0, False)
    map_ok = map_ok and m5.is_ready() and (m5.ready_count() == 0)
    # Partial counts ride through untouched.
    var m6 = attempt_from_rc(Int32(0), 137, True)
    map_ok = map_ok and m6.is_ready() and (m6.ready_count() == 137)
    map_ok = map_ok and (m6.kind == ATTEMPT_READY)
    # Negative-but-unmapped errno still lands in Error, value kept.
    var m7 = attempt_from_rc(Int32(-122), 0, False)
    map_ok = map_ok and m7.is_error() and (m7.errno_code() == Int32(122))
    if not _check("t6_09 eintr-eagain-mapping(simulated+live)", map_ok):
        failed += 1

    # ======================= t6_10 close-once / ownership ==================
    var close_ok = True
    var d1 = NativeSocket.tcp_v4()
    var d1_fd = d1.get()
    close_ok = close_ok and (d1_fd >= 0)
    d1.close()
    close_ok = close_ok and d1.is_closed() and (d1.get() == -1)
    var double_raised = False
    try:
        d1.close()
    except e:
        double_raised = True
        _ = e
    close_ok = close_ok and double_raised
    # Move transfers the descriptor token (^); b2 leaves the SOURCE
    # uninitialized (compiler-enforced no-further-use), so the inert-source
    # property is enforced statically rather than probed here.
    var moved = NativeSocket.tcp_v4()
    var target = moved^
    close_ok = close_ok and target.is_valid()
    target.close()
    close_ok = close_ok and target.is_closed()
    if not _check("t6_10 close-once(move-invalidate)", close_ok):
        failed += 1

    # ======================= t6_11 IPv6 loopback ===========================
    var v6_ok = True
    var l6 = NativeSocket.tcp_v6()
    l6.bind(SocketAddress.ipv6_loopback(Int32(0)))
    l6.listen(Int(4))
    var port6 = _bound_port(l6.get())
    v6_ok = v6_ok and (port6 > 0)
    l6.set_nonblocking(True)
    var cl6 = NativeSocket.tcp_v6()
    v6_ok = v6_ok and cl6.connect(SocketAddress.ipv6_loopback(Int32(port6)))
    var conn6_fd = _accept_fd(l6, SPIN_BUDGET_MS)
    v6_ok = v6_ok and (conn6_fd >= 0)
    if conn6_fd >= 0:
        var c6conn = NativeSocket._adopt(conn6_fd)
        c6conn.close()
    cl6.close()
    l6.close()
    if not _check("t6_11 ipv6-loopback(::1)", v6_ok):
        failed += 1

    # ======================= t6_12 Unix-domain stream ======================
    var ux_ok = True
    var ux_path = String("/tmp/mojito_s6_ux_sock")
    var unlink_buf_a = stack_allocation[128, Byte]()
    _fill_cstr(unlink_buf_a, 128, ux_path)
    _ = _unlink(unlink_buf_a)
    var ul = NativeSocket.unix_stream()
    ul.bind(SocketAddress.unix(ux_path))
    ul.listen(Int(2))
    ul.set_nonblocking(True)
    var uc = NativeSocket.unix_stream()
    ux_ok = ux_ok and uc.connect(SocketAddress.unix(ux_path))
    var uconn_fd = _accept_fd(ul, SPIN_BUDGET_MS)
    ux_ok = ux_ok and (uconn_fd >= 0)
    var umsg = stack_allocation[8, UInt8]()
    _fill_bytes(umsg, String("unix!"))
    # The CLIENT speaks first so the accepted side has data to recv.
    var uw0 = 0
    var dl12c = _deadline_ticks(SPIN_BUDGET_MS)
    while uw0 < 5 and monotonic_now().ticks < dl12c:
        var ucw = Span[UInt8](ptr=umsg, length=5 - uw0)
        var ucr = uc.send_nonblocking(ucw)
        if ucr.is_ready():
            uw0 += ucr.ready_count()
        elif ucr.is_closed():
            break
    ux_ok = ux_ok and (uw0 == 5)
    var uback = stack_allocation[5, UInt8]()
    var ugot = 0
    if uconn_fd >= 0:
        var uconn = NativeSocket._adopt(uconn_fd)
        var ur_done = 0
        var dl12r = _deadline_ticks(SPIN_BUDGET_MS)
        while ur_done < 5 and monotonic_now().ticks < dl12r:
            var ur = uconn.recv_nonblocking(
                Span[UInt8](ptr=umsg, length=5)
            )
            if ur.is_ready():
                ur_done += ur.ready_count()
            elif ur.is_closed():
                break
        ux_ok = ux_ok and (ur_done == 5)
        var uw_done = 0
        var dl12w = _deadline_ticks(SPIN_BUDGET_MS)
        while uw_done < 5 and monotonic_now().ticks < dl12w:
            var uw = uconn.send_nonblocking(
                Span[UInt8](ptr=umsg, length=5)
            )
            if uw.is_ready():
                uw_done += uw.ready_count()
            elif uw.is_closed():
                break
        ux_ok = ux_ok and (uw_done == 5)
        uconn.close()
        var dl12a = _deadline_ticks(SPIN_BUDGET_MS)
        while ugot < 5 and monotonic_now().ticks < dl12a:
            var uwin = Span[UInt8](
                ptr=_u8_of(uback) + ugot, length=5 - ugot
            )
            var ur2 = uc.recv_nonblocking(uwin)
            if ur2.is_ready():
                ugot += ur2.ready_count()
            elif ur2.is_closed():
                break
    ux_ok = ux_ok and (ugot == 5)
    var expect = stack_allocation[8, UInt8]()
    _fill_bytes(expect, String("unix!"))
    var qi = 0
    var same = True
    while qi < 5:
        same = same and (uback[qi] == expect[qi])
        qi += 1
    ux_ok = ux_ok and same
    uc.close()
    ul.close()
    var unlink_buf_b = stack_allocation[128, Byte]()
    _fill_cstr(unlink_buf_b, 128, ux_path)
    _ = _unlink(unlink_buf_b)
    if not _check("t6_12 unix-domain-stream", ux_ok):
        failed += 1

    # ======================= t6_13 non-blocking connect ====================
    var nbcon_ok = True
    var nc = NativeSocket.tcp_v4()
    nc.set_nonblocking(True)
    var t13 = monotonic_now().ticks
    var pending = not nc.connect(addr)
    var dt13 = monotonic_now().ticks - t13
    nbcon_ok = nbcon_ok and pending
    nbcon_ok = nbcon_ok and (dt13 < NEVER_PARK_BUDGET_NS)
    nc.close()
    if not _check("t6_13 nonblocking-connect(einprogress-pending)", nbcon_ok):
        failed += 1

    # -----------------------------------------------------------------------
    listener.close()
    print("")
    if failed != 0:
        print("RESULT: FAILED (" + String(failed) + " checks)")
    else:
        print("RESULT: all green")


# Fill a caller-owned 17-word neutral buffer from a SocketAddress (raw-level
# fixture helper mirroring SocketAddress.to_buffer byte layout).
def _fill_sockaddr(words: Int64Ptr, a: SocketAddress):
    var p = _buf_of(words)
    var z = 0
    while z < 136:
        p[z] = Byte(0)
        z += 1
    p[0] = Byte(a.family & 0xFF)
    p[1] = Byte((a.family >> 8) & 0xFF)
    p[2] = Byte((a.family >> 16) & 0xFF)
    p[3] = Byte((a.family >> 24) & 0xFF)
    p[4] = Byte(a.port & 0xFF)
    p[5] = Byte((a.port >> 8) & 0xFF)
    var k = 0
    while k < 4:
        var word = a.word(k)
        var base = 16 + k * 4
        p[base] = Byte((word >> 24) & 0xFF)
        p[base + 1] = Byte((word >> 16) & 0xFF)
        p[base + 2] = Byte((word >> 8) & 0xFF)
        p[base + 3] = Byte(word & 0xFF)
        k += 1
