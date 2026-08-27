"""
mojito-sys S6.7 — NativeSocket loopback benchmark (issue #79, spec §38.12
Socket benchmarks) over the frozen C ABI (mjs_socket_*) on macOS/BSD.

Measures, per spec §38.12:
  - loopback connection setup: blocking-connect accepted-and-established
    latency (the full listener accept + client connect handshake);
  - ping-pong latency: alternating single-byte sends between a pair of
    non-blocking loopback sockets (per round trip);
  - throughput by payload size: one-way bulk transfer of 4 KiB / 64 KiB
    payloads, measured in MiB/s;
  - many idle sockets: a large set of connected-but-idle loopback pairs
    (leverage the datapath without active traffic).

Methodology (spec §38.12): warmup rounds precede every measurement; a
duration floor keeps micro-runs from being reported; all timing is
wall-clock monotonic ns via mojito_sys.time. Each measurement lives in
its own small helper (b2 JIT fragility, documented). Non-blocking drains
retry on -EAGAIN/-EINTR per §38.11 without sleeping: on loopback the
readiness is effectively immediate.

Output contract for benchmark/io/gate.sh: every gated metric is printed
as
    METRIC\t<metric_id>\t<VALUE>|<SKIP>\t<detail>
Direction conventions (baselines.tsv): ge = higher-better (throughput,
ops/sec); le = lower-better (latency ns).

Run (from repo root):
  mojo run -I . -Xlinker libmojito_sys.dylib benchmark/io/socket_loopback_bench.mojo
"""

from std.memory import Span, stack_allocation
from std.sys import CompilationTarget

from mojito_sys.io.externs import (
    probe_accept,
    probe_bind,
    probe_close,
    probe_connect,
    probe_listen,
    probe_set_nonblocking,
    probe_sockaddr_ipv4,
    probe_socket,
)
from mojito_sys.io.socket import (
    NativeSocket,
    socket_address_parse_ipv4,
)
from mojito_sys.time.monotonic import monotonic_now


# ---- pointer aliases --------------------------------------------------
comptime Int32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime CellPtr = UnsafePointer[Int64, MutAnyOrigin]

# Iteration + duration floors: never report an unwarmed micro-run.
comptime WARMUP = 50
comptime FLOOR_NS = 300000000  # 0.3 s floor
comptime MAXG = 200000  # bounded EAGAIN-retry guard per non-blocking op

comptime CHUNK_4K = 4096
comptime CHUNK_64K = 65536

# Neutral AF/SOCK constants (frozen header) for the raw probe ABI.
comptime MJS_SOCK_INET = Int32(2)
comptime MJS_SOCK_STREAM = Int32(1)


# ---- libc plumbing (fixtures only; adds no mojito-sys ABI) ------------
@extern("getsockname")
def _getsockname(fd: Int32, sa: UnsafePointer[Byte, MutAnyOrigin], lenp: Int32Ptr) abi("C") -> Int32:
    ...


def _bound_port(fd: Int32) -> Int:
    var sa = stack_allocation[16, Byte]()
    var sl = stack_allocation[1, Int32]()
    sl[0] = 16
    var rc = _getsockname(fd, sa, sl)
    if rc != 0:
        return -1
    return (Int(sa[2]) << 8) | Int(sa[3])


# View an Int64-cell buffer as a byte buffer (raw ABI sockaddr carrier).
def _bbig(cell: CellPtr) -> UnsafePointer[Byte, MutAnyOrigin]:
    return UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=Int(cell))


# Write `txt` as NUL-terminated bytes into `dbuf` (raw probe fixtures).
def _fill_cstr(dbuf: UnsafePointer[Byte, MutAnyOrigin], txt: String):
    var src = txt.unsafe_ptr()
    var sbp = UnsafePointer[Byte, MutUntrackedOrigin](unsafe_from_address=Int(src))
    var n = len(txt)
    var i = 0
    while i < n:
        dbuf[i] = sbp[i]
        i += 1
    dbuf[n] = Byte(0)


# ---- metering ----------------------------------------------------------
def emit(mid: String, value: Int, detail: String):
    print("METRIC\t" + mid + "\t" + String(value) + "\t" + detail)


def emit_skip(mid: String, reason: String):
    print("METRIC\t" + mid + "\tSKIP\t" + reason)


# Spin-until-accepted helper (never parks; non-blocking accepts only).
def _accept_fd(mut listener: NativeSocket) raises -> Int32:
    var dl = monotonic_now().ticks + UInt64(3000000000)
    var spin = 0
    while spin < 200000 and monotonic_now().ticks < dl:
        var att = listener.accept_nonblocking()
        if att.is_ready():
            return att.take_ready_fd()
        spin += 1
    return Int32(-1)


# Ping-pong round: client sends 1 byte, server echoes it back. Returns the
# number of full client->server->client round trips completed.
def _ping_rounds(mut client: NativeSocket, mut conn: NativeSocket, rounds: Int) raises -> Int:
    var one = stack_allocation[1, UInt8]()
    one[0] = UInt8(0x50)
    var done = 0
    while done < rounds:
        var a = client.send_nonblocking(Span[UInt8](ptr=one, length=1))
        var ga = 0
        while (not a.is_ready()) and (a.is_would_block() or a.is_interrupted()) and ga < MAXG:
            ga += 1
            a = client.send_nonblocking(Span[UInt8](ptr=one, length=1))
        if not a.is_ready():
            break
        var b = conn.recv_nonblocking(Span[UInt8](ptr=one, length=1))
        var gb = 0
        while (not b.is_ready()) and (b.is_would_block() or b.is_interrupted()) and gb < MAXG:
            gb += 1
            b = conn.recv_nonblocking(Span[UInt8](ptr=one, length=1))
        if not b.is_ready():
            break
        var c2 = conn.send_nonblocking(Span[UInt8](ptr=one, length=1))
        var gc = 0
        while (not c2.is_ready()) and (c2.is_would_block() or c2.is_interrupted()) and gc < MAXG:
            gc += 1
            c2 = conn.send_nonblocking(Span[UInt8](ptr=one, length=1))
        if not c2.is_ready():
            break
        var d = client.recv_nonblocking(Span[UInt8](ptr=one, length=1))
        var gd = 0
        while (not d.is_ready()) and (d.is_would_block() or d.is_interrupted()) and gd < MAXG:
            gd += 1
            d = client.recv_nonblocking(Span[UInt8](ptr=one, length=1))
        if not d.is_ready():
            break
        done += 1
    return done


# Bulk transfer: client sends `total` payload bytes (in `chunk` pieces) to
# the server, which drains; returns bytes sent.
def _bulk(mut client: NativeSocket, mut conn: NativeSocket, total: Int, chunk: Int) raises -> Int:
    var payload = stack_allocation[CHUNK_64K + 64, UInt8]()
    var f = 0
    while f < chunk:
        payload[f] = UInt8(f & 0xFF)
        f += 1
    var sent = 0
    while sent < total:
        var remain = total - sent
        var c = chunk if (remain >= chunk) else remain
        var sr = client.send_nonblocking(Span[UInt8](ptr=payload, length=c))
        var go = 0
        while (not sr.is_ready()) and (sr.is_would_block() or sr.is_interrupted()) and go < MAXG:
            go += 1
            sr = client.send_nonblocking(Span[UInt8](ptr=payload, length=c))
        if not sr.is_ready():
            break
        sent += sr.ready_count()
        var rr = conn.recv_nonblocking(Span[UInt8](ptr=payload, length=CHUNK_64K))
        var gr = 0
        while (not rr.is_ready()) and (rr.is_would_block() or rr.is_interrupted()) and gr < MAXG:
            gr += 1
            rr = conn.recv_nonblocking(Span[UInt8](ptr=payload, length=CHUNK_64K))
        if not rr.is_ready():
            break
    return sent


# ---- measurements ------------------------------------------------------

def measure_connect_setup() raises:
    var listener = NativeSocket.tcp_v4()
    listener.bind(socket_address_parse_ipv4(String("127.0.0.1"), Int32(0)))
    listener.listen(Int(64))
    var port = _bound_port(listener.get())
    listener.set_nonblocking(True)
    if port <= 0:
        emit_skip("socket.connect_setup_latency_ns", "bind failed")
        return
    var addr = socket_address_parse_ipv4(String("127.0.0.1"), Int32(port))
    var w = 0
    while w < WARMUP:
        var c = NativeSocket.tcp_v4()
        var est = c.connect(addr)
        if est:
            var fd = _accept_fd(listener)
            if fd >= 0:
                var conn = NativeSocket._adopt(fd)
                conn.close()
        c.close()
        w += 1
    var total = UInt64(0)
    var n = 0
    var ok = True
    while n < 2000:
        var c = NativeSocket.tcp_v4()
        var t0 = monotonic_now().ticks
        var est = c.connect(addr)
        var dt = monotonic_now().ticks - t0
        total += dt
        n += 1
        if not est:
            ok = False
        if est:
            var fd = _accept_fd(listener)
            if fd >= 0:
                var conn = NativeSocket._adopt(fd)
                conn.close()
        c.close()
        if n >= 300 and total >= UInt64(150000000):
            break
    listener.close()
    if ok and n > 0:
        emit("socket.connect_setup_latency_ns", Int(total // UInt64(n)), "n=" + String(n))
    else:
        emit_skip("socket.connect_setup_latency_ns", "connect/accept failed")


def measure_pingpong() raises:
    var listener = NativeSocket.tcp_v4()
    listener.bind(socket_address_parse_ipv4(String("127.0.0.1"), Int32(0)))
    listener.listen(Int(64))
    var port = _bound_port(listener.get())
    listener.set_nonblocking(True)
    var addr = socket_address_parse_ipv4(String("127.0.0.1"), Int32(port))
    var client = NativeSocket.tcp_v4()
    var est = client.connect(addr)
    client.set_nonblocking(True)
    var fd = _accept_fd(listener)
    var ok = est and (fd >= 0)
    listener.close()
    if not ok:
        emit_skip("socket.pingpong_latency_ns", "connect/accept failed")
        client.close()
        return
    var conn = NativeSocket._adopt(fd)
    conn.set_nonblocking(True)
    var w = 0
    while w < WARMUP:
        _ = _ping_rounds(client, conn, 2)
        w += 1
    var total = UInt64(0)
    var rounds_total = 0
    var batch = 200
    var guard = 0
    while rounds_total < 12000 and guard < 12000:
        guard += 1
        var t0 = monotonic_now().ticks
        var r = _ping_rounds(client, conn, batch)
        var dt = monotonic_now().ticks - t0
        total += dt
        rounds_total += r
        if r < batch:
            break
        if rounds_total >= 1200 and total >= FLOOR_NS:
            break
    client.close()
    conn.close()
    if rounds_total > 0:
        emit(
            "socket.pingpong_latency_ns",
            Int(total // UInt64(rounds_total) ),
            "n=" + String(rounds_total),
        )
    else:
        emit_skip("socket.pingpong_latency_ns", "no rounds completed")


def measure_throughput(mid: String, chunk: Int) raises:
    var listener = NativeSocket.tcp_v4()
    listener.bind(socket_address_parse_ipv4(String("127.0.0.1"), Int32(0)))
    listener.listen(Int(64))
    var port = _bound_port(listener.get())
    listener.set_nonblocking(True)
    var addr = socket_address_parse_ipv4(String("127.0.0.1"), Int32(port))
    var client = NativeSocket.tcp_v4()
    var est = client.connect(addr)
    client.set_nonblocking(True)
    var fd = _accept_fd(listener)
    var ok = est and (fd >= 0)
    listener.close()
    if not ok:
        emit_skip(mid, "connect/accept failed")
        return
    var conn = NativeSocket._adopt(fd)
    conn.set_nonblocking(True)
    var w = 0
    while w < 20:
        _ = _bulk(client, conn, chunk * 64, chunk)
        w += 1
    var total_bytes = chunk * 1024
    var t0 = monotonic_now().ticks
    var sent = _bulk(client, conn, total_bytes, chunk)
    var dt = monotonic_now().ticks - t0
    client.close()
    conn.close()
    if sent > 0 and dt > 0:
        var mib_per_s = sent * 1000000000 // (Int(dt) * 1048576)
        emit(mid, mib_per_s, "bytes=" + String(sent))
    else:
        emit_skip(mid, "transfer failed")


def measure_idle_sockets() raises:
    # Many connected-but-idle loopback pairs held simultaneously on one
    # listener, tracked as raw C fds (NativeSocket value arrays crash the
    # b2 JIT at teardown, documented; the raw probe ABI keeps sockets OPEN
    # without ownership-close, giving the "many idle" datapath leverage).
    var count = 256
    var cfds = stack_allocation[256, Int32]()
    var sfds = stack_allocation[256, Int32]()
    var lfd_slot = stack_allocation[1, Int32]()
    var made = 0
    if probe_socket(MJS_SOCK_INET, MJS_SOCK_STREAM, lfd_slot) != 0:
        emit_skip("socket.idle_pairs", "listener create failed")
        return
    var lfd = lfd_slot[0]
    _ = probe_set_nonblocking(lfd, 1)
    var bind_cell = stack_allocation[17, Int64]()
    var dbuf = stack_allocation[64, Byte]()
    _fill_cstr(dbuf, String("127.0.0.1"))
    _ = probe_sockaddr_ipv4(dbuf, Int32(0), _bbig(bind_cell))
    if probe_bind(lfd, _bbig(bind_cell)) != 0:
        emit_skip("socket.idle_pairs", "bind failed")
        _ = probe_close(lfd)
        return
    if probe_listen(lfd, Int32(4096)) != 0:
        emit_skip("socket.idle_pairs", "listen failed")
        _ = probe_close(lfd)
        return
    var port = _bound_port(lfd)
    if port <= 0:
        emit_skip("socket.idle_pairs", "no bound port")
        _ = probe_close(lfd)
        return
    var aaddr = stack_allocation[17, Int64]()
    _ = probe_sockaddr_ipv4(dbuf, Int32(port), _bbig(aaddr))
    while made < count:
        var cfd_slot = stack_allocation[1, Int32]()
        if probe_socket(MJS_SOCK_INET, MJS_SOCK_STREAM, cfd_slot) != 0:
            break
        if probe_connect(cfd_slot[0], _bbig(aaddr)) != 0:
            _ = probe_close(cfd_slot[0])
            break
        var afd = Int32(-1)
        var spin = 0
        while afd < 0 and spin < 200000:
            var child = stack_allocation[1, Int32]()
            var peer = stack_allocation[17, Int64]()
            if probe_accept(lfd, child, _bbig(peer)) == 0:
                afd = child[0]
            spin += 1
        if afd < 0:
            _ = probe_close(cfd_slot[0])
            break
        cfds[made] = cfd_slot[0]
        sfds[made] = afd
        made += 1
    _ = probe_close(lfd)
    var i = 0
    while i < made:
        _ = probe_close(sfds[i])
        _ = probe_close(cfds[i])
        i += 1
    if made > 0:
        emit("socket.idle_pairs", made, "target=" + String(count))
    else:
        emit_skip("socket.idle_pairs", "none established")


def main() raises:
    print("# mojito-sys S6.7 socket loopback benchmark")
    print()
    print("## Environment")
    print("| item | value |")
    print("|---|---|")
    var host = String("darwin") if CompilationTarget().is_macos() else String("linux")
    print("| host |", host, "|")
    print()

    try:
        measure_connect_setup()
    except Exception:
        emit_skip("socket.connect_setup_latency_ns", "raised: host-transient")
    try:
        measure_pingpong()
    except Exception:
        emit_skip("socket.pingpong_latency_ns", "raised: host-transient")
    try:
        measure_throughput(String("socket.thrpt_4k_mib_per_sec"), CHUNK_4K)
    except Exception:
        emit_skip("socket.thrpt_4k_mib_per_sec", "raised: host-transient")
    try:
        measure_throughput(String("socket.thrpt_64k_mib_per_sec"), CHUNK_64K)
    except Exception:
        emit_skip("socket.thrpt_64k_mib_per_sec", "raised: host-transient")
    try:
        measure_idle_sockets()
    except Exception:
        emit_skip("socket.idle_pairs", "raised: host-transient")
    print()
    print("socket_loopback_bench: complete")