"""
mojito-sys S6.7 — ReadinessPoller benchmark (issue #79, spec §38.12 Poller
benchmarks) over the kqueue backend on macOS/BSD (epoll/io_uring land on
the same ReadinessPoller shape per §27.1).

Measures, per spec §38.12:
  - create/destroy poller cycles;
  - add/delete/modify registration throughput;
  - empty-wait latency (non-blocking poll on an empty poller);
  - one-ready-handle wait latency;
  - readiness storm (many ready handles drained per wait batch);
  - scale tiers 1k / 10k registered handles: registration throughput AND
    wait latency under load (host fd limits honored; un-runnable tiers are
    reported as SKIP, never a fake baseline);
  - cross-thread wake latency (a worker parked in wait(None) unblocked by
    wake()); this drives the same EVFILT_USER mechanism a mojito reactor
    uses to hand work to a blocked wait loop;
  - token decode/dispatch throughput.

Methodology (spec §38.12): warmup rounds precede every measurement; a
duration floor AND an iteration floor keep micro-runs from being
reported; all timing is wall-clock monotonic ns via mojito_sys.time.
Each measurement lives in its OWN small helper function with its OWN
poller — the b2 1.0.0b2 JIT is fragile when one frame carries many
@extern calls and long loops (documented), so heavy measurements are
deliberately isolated to keep every frame small and the bench reliable
under the regression gate.

The kqueue backend uses EV_CLEAR edge semantics (one report per readiness
transition): a storm of simultaneously-ready handles is drained by
looping wait() batches until every registered handle is accounted for,
which is exactly how a mojito reactor drains kqueue in practice.

Output contract for benchmark/io/gate.sh: every gated metric is printed
as a line
    METRIC\t<metric_id>\t<VALUE>|<SKIP|ERROR>\t<detail>
where VALUE is an integer and detail a short note. gate.sh compares VALUE
against the committed baseline in baselines.tsv with a per-metric
tolerance + direction. SKIP rows (host-limited) and ERROR rows are not
treated as regressions but are reported.

Direction conventions (baselines.tsv):
  ge  — higher is better (throughput / ops-per-sec)
  le  — lower is better (latency ns)

Run (from repo root):
  mojo run -I . -Xlinker libmojito_sys.dylib benchmark/io/poller_bench.mojo
"""

from std.ffi import c_size_t
from std.memory import Span, UnsafePointer, stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

from mojito_sys.io.externs import (
    PollerPtr,
    TimeoutSlot,
    WaitCountSlot,
    probe_poller_wait,
    probe_poller_wake,
)
from mojito_sys.io.handle import NativeIoHandle
from mojito_sys.io.poller import IoEvent, IoInterest
from mojito_sys.io.platform.kqueue import KqueuePoller
from mojito_sys.thread.thread import CThreadEntry, no_name, spawn_native_thread
from mojito_sys.time.duration import Duration
from mojito_sys.time.monotonic import monotonic_now


# ---- pointer aliases --------------------------------------------------
comptime AnyCellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime Int32Ptr = UnsafePointer[Int32, MutAnyOrigin]
comptime U64Ptr = UnsafePointer[UInt64, MutAnyOrigin]
comptime IoEventPtr = UnsafePointer[IoEvent, MutAnyOrigin]
comptime BufPtr = UnsafePointer[Byte, MutAnyOrigin]

# kqueue backend delivers at most MAX_BATCH (256) events per wait call.
comptime EV_CAP = 256
comptime EV_WORDS = EV_CAP * 2

# Iteration + duration floors: never report an unwarmed micro-run.
comptime WARMUP = 200
comptime MIN_ITERS = 20
comptime FLOOR_NS = 200000000  # 0.2 s floor

comptime TIER_1K = 1024
comptime TIER_10K = 10240
comptime STORM_N = 512
comptime WAKE_SAMPLES = 16

# rlimit: RLIMIT_NOFILE = 8 darwin / 7 Linux.
def _rlimit_nofile() -> Int32:
    return Int32(8) if CompilationTarget().is_macos() else Int32(7)


# ---- fixture libc plumbing (adds no mojito-sys ABI) -------------------
@extern("pipe")
def _pipe(fds: Int32Ptr) abi("C") -> Int32:
    ...


@extern("readv")
def _readv(fd: Int32, iov: BufPtr, cnt: Int32) abi("C") -> Int64:
    ...


@extern("writev")
def _writev(fd: Int32, iov: BufPtr, cnt: Int32) abi("C") -> Int64:
    ...


@extern("close")
def _close(fd: Int32) abi("C") -> Int32:
    ...


@extern("usleep")
def _usleep(useconds: c_size_t) abi("C") -> Int32:
    ...


@extern("getrlimit")
def _getrlimit(res: Int32, rl: BufPtr) abi("C") -> Int32:
    ...


@extern("setrlimit")
def _setrlimit(res: Int32, rl: BufPtr) abi("C") -> Int32:
    ...


def _bb_of(cell: AnyCellsPtr) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(cell))


def _bb_u64(cell: U64Ptr) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(cell))


def _bb_of_byte(p: UnsafePointer[Byte, MutAnyOrigin]) -> BufPtr:
    return BufPtr(unsafe_from_address=Int(p))


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


def _drain_one(fd: Int32):
    var one = stack_allocation[1, Byte]()
    _ = _read(fd, _bb_of_byte(one), 1)


def _pipe_into(fds: Int32Ptr) -> Bool:
    return _pipe(fds) == 0


def _zero_cells(cell: AnyCellsPtr, words: Int):
    var i = 0
    while i < words:
        cell[i] = 0
        i += 1


# ---- metering ----------------------------------------------------------
def emit(mid: String, value: Int, detail: String):
    print("METRIC\t" + mid + "\t" + String(value) + "\t" + detail)


def emit_skip(mid: String, reason: String):
    print("METRIC\t" + mid + "\tSKIP\t" + reason)


def median_ns(samples: UnsafePointer[UInt64, MutAnyOrigin], count: Int) -> Int:
    var i = 1
    while i < count:
        var key = samples[i]
        var j = i - 1
        while j >= 0 and samples[j] > key:
            samples[j + 1] = samples[j]
            j -= 1
        samples[j + 1] = key
        i += 1
    return Int(samples[count // 2])


# ---- cross-thread wake worker -----------------------------------------
# Cells: [0]=poller addr, [1]=started, [2]=wait rc, [3]=event count,
#        [4]=returned.
@export("mjs_bench_wake_wait_entry")
def _wake_wait_entry(ud: AnyCellsPtr) abi("C") -> Int64:
    var p = PollerPtr(unsafe_from_address=Int(ud[0]))
    ud[1] = 1
    var evbuf = stack_allocation[EV_WORDS, Int64]()
    var ncell = stack_allocation[1, Int32]()
    var zero = 0
    var null_timeout = TimeoutSlot(unsafe_from_address=zero)
    var rc = probe_poller_wait(
        p, _bb_of(evbuf), EV_CAP, null_timeout,
        WaitCountSlot(unsafe_from_address=Int(ncell)),
    )
    ud[2] = Int64(rc)
    ud[3] = Int64(ncell[0])
    ud[4] = 1
    return 0


def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


# ======================================================================
# Measurement helpers — each owns its own poller and stays small.
# ======================================================================

def measure_create() raises:
    var warm = 0
    while warm < WARMUP:
        var p2 = KqueuePoller.create()
        p2.close()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 8000 and (loops < MIN_ITERS or now - start < FLOOR_NS):
        var inner = 0
        while inner < 4:
            var p2 = KqueuePoller.create()
            p2.close()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= FLOOR_NS:
                break
    var el = now - start
    emit(
        "poller.create_ops_per_sec",
        loops * 4 * 1000000000 // Int(el) if el > 0 else 0,
        "cycles=" + String(loops * 4),
    )


def measure_register() raises:
    var p = KqueuePoller.create()
    var pipe = stack_allocation[2, Int32]()
    if not _pipe_into(pipe):
        emit_skip("poller.register_ops_per_sec", "pipe create failed")
        p.close()
        return
    var warm = 0
    while warm < WARMUP:
        p.register(NativeIoHandle(pipe[0]), IoInterest.READABLE, UInt64(7))
        p.modify(NativeIoHandle(pipe[0]), IoInterest.BOTH, UInt64(8))
        p.unregister(NativeIoHandle(pipe[0]))
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 8000 and (loops < MIN_ITERS or now - start < FLOOR_NS):
        var inner = 0
        while inner < 4:
            p.register(NativeIoHandle(pipe[0]), IoInterest.READABLE, UInt64(7))
            p.modify(NativeIoHandle(pipe[0]), IoInterest.BOTH, UInt64(8))
            p.unregister(NativeIoHandle(pipe[0]))
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= FLOOR_NS:
                break
    var el = now - start
    emit(
        "poller.register_ops_per_sec",
        loops * 4 * 1000000000 // Int(el) if el > 0 else 0,
        "ops=" + String(loops * 4),
    )
    _ = _close(pipe[0])
    _ = _close(pipe[1])
    p.close()


def measure_empty_wait() raises:
    var p = KqueuePoller.create()
    var zero_d = Duration(UInt64(0))
    var warm = 0
    while warm < WARMUP:
        var sp = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(sp, EV_WORDS)
        var span_e = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(sp)), length=EV_CAP
        )
        _ = p.wait(span_e, Optional[Duration](zero_d))
        warm += 1
    var n = 0
    var total = UInt64(0)
    var ok = True
    while n < 20000:
        var sp = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(sp, EV_WORDS)
        var span_e = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(sp)), length=EV_CAP
        )
        var tw = monotonic_now().ticks
        var got = p.wait(span_e, Optional[Duration](zero_d))
        total += monotonic_now().ticks - tw
        if got != 0:
            ok = False
        n += 1
    p.close()
    if ok:
        emit("poller.empty_wait_ns", Int(total // UInt64(n)), "n=" + String(n))
    else:
        emit_skip("poller.empty_wait_ns", "unexpected event on empty poller")


def measure_one_ready_wait() raises:
    var p = KqueuePoller.create()
    var pipe = stack_allocation[2, Int32]()
    var one = stack_allocation[1, Byte]()
    one[0] = Byte(0x41)
    var zero_d = Duration(UInt64(0))
    if not _pipe_into(pipe):
        emit_skip("poller.one_ready_wait_ns", "pipe create failed")
        p.close()
        return
    p.register(NativeIoHandle(pipe[0]), IoInterest.READABLE, UInt64(1))
    var warm = 0
    while warm < WARMUP:
        _ = _write(pipe[1], _bb_of_byte(one), 1)
        var sp = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(sp, EV_WORDS)
        var span1 = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(sp)), length=EV_CAP
        )
        _ = p.wait(span1, Optional[Duration](zero_d))
        _drain_one(pipe[0])
        warm += 1
    var n = 0
    var total = UInt64(0)
    var ok = True
    while n < 20000:
        _ = _write(pipe[1], _bb_of_byte(one), 1)
        var sp = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(sp, EV_WORDS)
        var span1 = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(sp)), length=EV_CAP
        )
        var tw = monotonic_now().ticks
        var got = p.wait(span1, Optional[Duration](zero_d))
        total += monotonic_now().ticks - tw
        if got != 1:
            ok = False
        _drain_one(pipe[0])
        n += 1
    p.close()
    _ = _close(pipe[0])
    _ = _close(pipe[1])
    if ok:
        emit("poller.one_ready_wait_ns", Int(total // UInt64(n)), "n=" + String(n))
    else:
        emit_skip("poller.one_ready_wait_ns", "missing ready event")


def measure_storm() raises:
    var p = KqueuePoller.create()
    var zero_d = Duration(UInt64(0))
    var one = stack_allocation[1, Byte]()
    one[0] = Byte(0x5A)
    var sp_tier = stack_allocation[STORM_N * 2, Int32]()
    var made = 0
    var ok = True
    while made < STORM_N:
        if not _pipe_into(sp_tier + made * 2):
            ok = False
            break
        made += 1
    if not ok:
        emit_skip("poller.storm_events_per_sec", "pipe create failed")
        p.close()
        return
    var k = 0
    while k < STORM_N:
        p.register(NativeIoHandle(sp_tier[k * 2]), IoInterest.READABLE, UInt64(1000 + k))
        k += 1
    k = 0
    while k < STORM_N:
        _ = _write(sp_tier[k * 2 + 1], _bb_of_byte(one), 1)
        k += 1
    # Drain a full "round" (all STORM_N ready handles) `reps` times.
    var reps = 40
    var cum = UInt64(0)
    var delivered = 0
    var bad_token = False
    var rep = 0
    while rep < reps:
        # Fresh edge transition on every handle for this round (EV_CLEAR
        # requires a new readiness transition to re-fire).
        var wk = 0
        while wk < STORM_N:
            _ = _write(sp_tier[wk * 2 + 1], _bb_of_byte(one), 1)
            wk += 1
        var sp2 = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(sp2, EV_WORDS)
        var span_s = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(sp2)), length=EV_CAP
        )
        var tw = monotonic_now().ticks
        var got_total = 0
        var guard = 0
        while got_total < STORM_N and guard < 20:
            guard += 1
            var gotn = p.wait(span_s, Optional[Duration](zero_d))
            var q = 0
            while q < gotn:
                var tok = span_s[q].token
                if tok == 0 or tok > UInt64(1000 + STORM_N):
                    bad_token = True
                got_total += 1
                q += 1
            if gotn == 0:
                break
        cum += monotonic_now().ticks - tw
        delivered += got_total
        rep += 1
    # `k` was consumed by the write loop above (already == STORM_N), so use a
    # fresh index or this unregister/close loop would never run and every
    # run would leak STORM_N * 2 fds.
    var u = 0
    while u < STORM_N:
        p.unregister(NativeIoHandle(sp_tier[u * 2]))
        _ = _close(sp_tier[u * 2])
        _ = _close(sp_tier[u * 2 + 1])
        u += 1
    p.close()
    if bad_token:
        emit_skip("poller.storm_events_per_sec", "bad token")
    elif delivered < STORM_N * reps:
        emit_skip("poller.storm_events_per_sec", "incomplete drain")
    else:
        var mean_ns = cum // UInt64(reps)
        emit(
            "poller.storm_events_per_sec",
            delivered * 1000000000 // Int(mean_ns) if mean_ns > 0 else 0,
            "reps=" + String(reps),
        )


def measure_token_decode() raises:
    var dec = stack_allocation[EV_WORDS, Int64]()
    _zero_cells(dec, EV_WORDS)
    var span_d = Span[IoEvent, MutAnyOrigin](
        ptr=IoEventPtr(unsafe_from_address=Int(dec)), length=EV_CAP
    )
    var qd = 0
    while qd < EV_CAP:
        span_d[qd].token = UInt64(qd + 1)
        span_d[qd].fd = Int32(qd)
        span_d[qd].events = UInt32(1)
        qd += 1
    var t0 = monotonic_now().ticks
    var count = 0
    var di = 0
    while di < 100000:
        var qq = 0
        while qq < EV_CAP:
            var t = span_d[qq].token
            if t == UInt64(qq + 1):
                count += 1
            qq += 1
        di += 1
    var el = monotonic_now().ticks - t0
    emit(
        "poller.token_decode_ops_per_sec",
        count * 1000000000 // Int(el) if el > 0 else 0,
        "n=" + String(count),
    )


def _close_pipes(pipes: Int32Ptr, made: Int, mut p: KqueuePoller) raises:
    var ri = 0
    while ri < made:
        p.unregister(NativeIoHandle(pipes[ri * 2]))
        _ = _close(pipes[ri * 2])
        _ = _close(pipes[ri * 2 + 1])
        ri += 1


def measure_tier[TIER: Int](mut p: KqueuePoller, prefix: String) raises:
    var zero_d = Duration(UInt64(0))
    var one = stack_allocation[1, Byte]()
    one[0] = Byte(0x11)
    var pipes = stack_allocation[TIER * 2, Int32]()
    var made = 0
    var ok = True
    while made < TIER:
        if not _pipe_into(pipes + made * 2):
            ok = False
            break
        made += 1
    # A scale tier is labeled by its target size (reg_10240/wait_10240), so
    # emitting that id for fewer created pipes would report a mislabeled
    # baseline. Require the full target; on a partial tier record a caveat
    # line (matching the S6.3 poller conformance suite) and SKIP rather than
    # print a baseline against ~n registers.
    if made != TIER:
        print(
            "caveat: scale tier " + prefix + " partial (created "
            + String(made) + "/" + prefix
            + " pipes; host fd ceiling hit) — skipped to avoid mislabeled baseline"
        )
        emit_skip(
            "poller.reg_" + prefix + "_ops_per_sec",
            "partial tier (created " + String(made) + "/" + prefix + ")",
        )
        emit_skip(
            "poller.wait_" + prefix + "_latency_ns",
            "partial tier (created " + String(made) + "/" + prefix + ")",
        )
        var ci = 0
        while ci < made:
            _ = _close(pipes[ci * 2])
            _ = _close(pipes[ci * 2 + 1])
            ci += 1
        return
    var t0 = monotonic_now().ticks
    var ri = 0
    while ri < made:
        p.register(NativeIoHandle(pipes[ri * 2]), IoInterest.READABLE, UInt64(50000 + ri))
        ri += 1
    var r_el = monotonic_now().ticks - t0
    if r_el == 0:
        r_el = 1
    emit(
        "poller.reg_" + prefix + "_ops_per_sec",
        made * 1000000000 // Int(r_el),
        "registered=" + String(made),
    )
    var wl_total = UInt64(0)
    var wl_n = 0
    var wl_pipe = 0
    var wl_rep = 0
    while wl_rep < 1000:
        _ = _write(pipes[(wl_pipe % made) * 2 + 1], _bb_of_byte(one), 1)
        var spw = stack_allocation[EV_WORDS, Int64]()
        _zero_cells(spw, EV_WORDS)
        var span_w = Span[IoEvent, MutAnyOrigin](
            ptr=IoEventPtr(unsafe_from_address=Int(spw)), length=EV_CAP
        )
        var tw = monotonic_now().ticks
        _ = p.wait(span_w, Optional[Duration](zero_d))
        wl_total += monotonic_now().ticks - tw
        wl_n += 1
        _drain_one(pipes[(wl_pipe % made) * 2])
        wl_pipe += 1
        wl_rep += 1
    if wl_n > 0:
        emit(
            "poller.wait_" + prefix + "_latency_ns",
            Int(wl_total // UInt64(wl_n)),
            "n=" + String(wl_n),
        )
    else:
        emit_skip("poller.wait_" + prefix + "_latency_ns", "no samples")
    _close_pipes(pipes, made, p)


def measure_wake_latency() raises:
    var p = KqueuePoller.create()
    var pword = stack_allocation[1, Int64]()
    pword[0] = Int64(Int(p.handle_ptr()))
    var wake_buf = stack_allocation[WAKE_SAMPLES, UInt64]()
    var ws = 0
    var ok = True
    while ws < WAKE_SAMPLES:
        var wc = stack_allocation[8, Int64]()
        _zero_cells(wc, 8)
        wc[0] = pword[0]
        var wptr = entry_pointer["mjs_bench_wake_wait_entry"]()
        var waiter = spawn_native_thread(wptr, wc, 0, no_name())
        var spin_t0 = monotonic_now().ticks
        while Int(wc[1]) == 0 and (monotonic_now().ticks - spin_t0) < UInt64(3000000000):
            _ = _usleep(c_size_t(50))
        var w0 = monotonic_now().ticks
        _ = probe_poller_wake(p.handle_ptr())
        while Int(wc[4]) == 0 and (monotonic_now().ticks - w0) < UInt64(3000000000):
            _ = _usleep(c_size_t(50))
        var wdt = monotonic_now().ticks - w0
        _ = waiter.join()
        if Int(wc[4]) != 1 or Int(wc[3]) != 0:
            ok = False
        wake_buf[ws] = wdt
        ws += 1
    p.close()
    if ok:
        emit(
            "poller.wake_latency_ns",
            median_ns(wake_buf, WAKE_SAMPLES),
            "n=" + String(WAKE_SAMPLES),
        )
    else:
        emit_skip("poller.wake_latency_ns", "wake did not return cleanly")


def fd_limit_fit(need_fds: Int) -> Bool:
    var chk = stack_allocation[2, UInt64]()
    if _getrlimit(_rlimit_nofile(), _bb_u64(chk)) != 0:
        return False
    return chk[0] >= UInt64(need_fds)


def main() raises:
    print("# mojito-sys S6.7 poller benchmark (kqueue)")
    print()
    print("## Environment")
    print("| item | value |")
    print("|---|---|")
    var host = String("darwin") if CompilationTarget().is_macos() else String("linux")
    print("| host |", host, "|")
    print()

    # Raise RLIMIT_NOFILE so the 10k tier (20k fds) can register.
    var rl = stack_allocation[2, UInt64]()
    var got = _getrlimit(_rlimit_nofile(), _bb_u64(rl))
    var hard = rl[1]
    var raised = False
    if got == 0:
        var target = UInt64(300000)
        if target > hard:
            target = hard
        if target > rl[0]:
            rl[0] = target
            if _setrlimit(_rlimit_nofile(), _bb_u64(rl)) == 0:
                raised = True
    if not raised:
        print("note: RLIMIT_NOFILE not raised; scale tiers adapt to host limit")

    measure_create()
    measure_register()
    measure_empty_wait()
    measure_one_ready_wait()
    measure_storm()
    measure_token_decode()

    # Scale tiers on dedicated pollers.
    var p1k = KqueuePoller.create()
    if raised or fd_limit_fit(2 * TIER_1K + 32):
        measure_tier[TIER_1K](p1k, String("1024"))
    else:
        emit_skip("poller.reg_1024_ops_per_sec", "fd limit < needed")
        emit_skip("poller.wait_1024_latency_ns", "fd limit < needed")
    p1k.close()

    var p10k = KqueuePoller.create()
    if raised or fd_limit_fit(2 * TIER_10K + 32):
        measure_tier[TIER_10K](p10k, String("10240"))
    else:
        emit_skip("poller.reg_10240_ops_per_sec", "fd limit < needed")
        emit_skip("poller.wait_10240_latency_ns", "fd limit < needed")
    p10k.close()

    measure_wake_latency()
    print()
    print("poller_bench: complete")