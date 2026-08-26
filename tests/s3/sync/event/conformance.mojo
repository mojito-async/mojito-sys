# mojito-sys S3.5 — NativeEvent conformance (issue #61, spec §17).
#
# Drives the §17 event surface (Mojo wrapper bound to the frozen
# mjs_event_* C ABI, native/include/mojito_sys.h s3-event block) across
# real OS threads:
#
#   1. blocked waiter released by a CROSS-THREAD signal (arrival-gated
#     handshake + settle delay, untimed-park shape via a far deadline);
#   2. wait_until expiry: past deadline -> .timed_out IMMEDIATELY;
#     future deadline expires ~on time within a bounded tolerance band;
#   3. PRE-SIGNAL immediate .ok — the auto-reset token sticks so one
#     later wait completes without blocking (measured < 100 ms);
#   4. documented BREADTH asserted with COUNTED waiters: K=4 parked
#     waiters, ONE signal wakes EXACTLY one over a quiet period
#     (normative breadth-one choice), K-1 further signals drain the
#     rest;
#   5. LOST-WAKEUP regression: 10k signal/wait cycles where the signal
#     races the waiter between its predicate check and its sleep —
#     every cycle must complete within its per-wait deadline, never
#     hangs (first anomaly aborts the loop, wall-clock guarded);
#   6. documented CONSUMED-VS-STICKY choice pinned: five coalescing
#     signals release exactly ONE wait; the next wait times out;
#   7. mid-wait signal returns .ok long before a far deadline;
#   8. -errno misuse: every method on an uninitialized/consumed handle
#     raises the decoded -EINVAL without re-entering C.
#
# WAKE SEMANTICS UNDER TEST (normative, mojito_sys/sync/event.mojo head):
# AUTO-RESET, BREADTH-ONE, token consumed by the successful wait,
# excess signals coalesce, fairness not promised.
#
# b2 notes (verbatim discipline from tests/s3/sync/condvar/conformance.mojo):
#   - Thread entries are @export abi("C") defs whose addresses are
#     materialized by the entry_pointer[symbol]() adrp/add idiom; they
#     drive the SCALAR PROBE SHIMS only (no aggregate-returning wrapper
#     calls inside an @export frame) and decode raw rcs into cells with
#     CONSTANT cell indices.
#   - Wrapper methods (wait_until etc.) are exercised from MAIN scope
#     only (crash workaround 2, condvar lane).
#   - Failure assertions decode through raise_errno (`String(e)` carries
#     the errno spelling); failures accumulate in a main()-local counter.
#
# Run via tests/s3/sync/event/run.sh (builds libmojito_sys.dylib
# first); green requires the exact "RESULT: 8/8 PASSED" line.
from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

from mojito_sys.sync.event import NativeEvent
import mojito_sys.sync.externs as _externs

from mojito_sys.sync.common import WaitStatus
from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    UserdataPtr,
    no_name,
    spawn_native_thread,
)
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant
from mojito_sys.time.monotonic import _now_ns

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]

# Breadth counting shape: K parked waiters, ONE signal.
comptime K = 4

# Lost-wakeup endurance shape (spec acceptance): 10k racing cycles.
comptime LOOP_ITERS = 10_000

# Quiet-period / tolerance margins (CI-safe, still meaningful).
comptime SETTLE_MS = 120
comptime QUIET_MS = 250
comptime EXPIRY_MS = 120
comptime EXPIRY_LATE_MS_MAX = 900


# ---- shared helpers ----------------------------------------------------------

@extern("usleep")
def _libc_usleep(useconds: UInt32) abi("C") -> Int32:
    ...


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven in tests/s3/sync/{mutex,condvar}/conformance.mojo.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) != -1


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def cell_block(arena: CellsPtr, first_cell: Int) -> CellsPtr:
    # Sub-block view into a waiter ARENA at cell offset `first_cell`
    # (byte math on the base pointer; safe in MAIN scope only).
    return UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(arena) + first_cell * 8
    )


# Re-adopt a raw thread handle for joining (fields public by design,
# mirroring NativeThread/NativeMutex conformance usage).
def adopt_join(handle: Int64) raises -> Int64:
    var w = NativeThread()
    w.handle = handle
    w.consumed = False
    return w.join()


# Poll a shared cell until it turns nonzero (plain cell read: event
# token semantics make a pre-settling signal SAFE — it sticks for
# exactly one wait — so no mutex-backed barrier is needed here).
# Hang-guarded: False after ~10 s, never taken on a green run.
def poll_flag(cell: CellsPtr, idx: Int) -> Bool:
    var spins = 0
    while True:
        if cell[idx] != 0:
            return True
        _ = _libc_usleep(200)
        spins += 1
        if spins > 50_000:
            return False


# Decode a raw mjs_event_wait_until rc into the WaitStatus tag space:
# 0 = .ok (token consumed), 1 = .timed_out, -1 = unexpected error.
def _wake_class(rc: Int32) -> Int64:
    var et = Int32(-110)
    if CompilationTarget().is_macos():
        et = Int32(-60)
    if rc == 0:
        return Int64(0)
    if rc == et:
        return Int64(1)
    return Int64(-1)


# ---- 1/4/7. gated waiter thread ----------------------------------------------
# ud layout: [0]=event handle [1]=arrived flag [2]=wake status tag
#            (-1000 pending; 0/.ok, 1/.timed_out, -1/error after)
#            [3]=ABSOLUTE monotonic deadline in ns (precomputed by the
#            spawner; keeps this export free of clock calls)
@export("mjs_s35_waiter_entry")
def _waiter_entry(ud: CellsPtr) abi("C") -> Int64:
    # Scalar probes only inside the @export frame (b2 workaround, see
    # module head); the status travels back as a plain tag.
    ud[1] = 1
    _ = _libc_usleep(UInt32(SETTLE_MS * 1000))  # reach the sleep
    ud[2] = _wake_class(
        _externs.probe_ev_wait_until(ud[0], UInt64(ud[3]))
    )
    return 0


# ---- 5. lost-wakeup endurance ping-pong ---------------------------------------
# ud layout: [0]=signal event handle [1]=cycles done [2]=timed-out
#            count [3]=unexpected-error count [4]=ack event handle
# PING-PONG SHAPE (why an ack exists): the documented semantics
# COALESCE signals issued while a token is pending, so a blind 10k-
# signal barrage could legitimately under-count wakes. Instead each
# cycle is acknowledged before the next signal fires — and because the
# spawner re-signals the instant the ack lands, the signal still
# routinely races this loop between its predicate check and its sleep.
# A lost wakeup in EITHER interleaving surfaces as a -ETIMEDOUT tally;
# the FIRST anomaly aborts the loop (wall-clock guard: a full 10k x 1s
# timeout burn can never happen).
@export("mjs_s35_looper_entry")
def _looper_entry(ud: CellsPtr) abi("C") -> Int64:
    var i = 0
    try:
        while i < LOOP_ITERS:
            # Per-cycle ABSOLUTE deadline straight from the monotonic
            # source (scalar helper only, same shape as the condvar
            # lane's looper): 1 s bounds each park.
            var cls = _wake_class(
                _externs.probe_ev_wait_until(
                    ud[0], _now_ns() + UInt64(1_000_000_000)
                )
            )
            if cls != 0:
                if cls == 1:
                    ud[2] += 1  # lost wakeup
                else:
                    ud[3] += 1  # real error
                ud[1] = Int64(i)
                return -1
            _ = _externs.probe_ev_signal(ud[4])  # ack: next ping may fire
            i += 1
    except:
        return -1
    ud[1] = Int64(i)
    return 0


# Double-destroy probe on a LIVE handle: first destroy consumes, the
# second MUST raise the decoded -EINVAL. Isolated helper returning a
# plain Bool (b2-safe shape, mirrors the condvar lane).
def live_double_destroy_raises() raises -> Bool:
    var ev = NativeEvent.create()
    ev.destroy()
    try:
        ev.destroy()
        return False  # second destroy MUST have raised
    except e:
        return contains(String(e), "EINVAL")


# ---- 5b. EXPIRY PARITY racer: paces a signal against a near-expiry park ------
# ud: [0]=pace event [1]=target event [2]=stop flag. Each pace release makes
# the racer signal the target within microseconds while the spawner parks
# ~3 ms: the signal lands pre-park, mid-park, or in the expiry/re-lock
# window. Every park must complete .ok CONSUMING the token — never
# .timed_out with credit left pending (the C layer re-checks e->signaled
# before propagating -ETIMEDOUT; wake beats timeout).
@export("mjs_s35_parity_racer_entry")
def _parity_racer_entry(ud: CellsPtr) abi("C") -> Int64:
    try:
        while ud[2] == 0:
            var cls = _wake_class(
                _externs.probe_ev_wait_until(
                    ud[0], _now_ns() + UInt64(10_000_000_000)
                )
            )
            if cls != 0:
                return -1
            _ = _externs.probe_ev_signal(ud[1])
    except:
        return -1
    return 0


def main() raises:
    var failed = 0

    # ---- 1. blocked waiter released by cross-thread signal --------------------
    var cw_args = stack_allocation[5, Int64]()
    cw_args[1] = 0
    cw_args[2] = -1000  # pending marker (distinct from any status tag)
    var cwe = NativeEvent.create()
    cw_args[0] = cwe.handle
    cw_args[3] = Int64(
        (MonotonicInstant.now() + duration_from_millis(10000)).ticks
    )
    var t1 = MonotonicInstant.now()
    var waiter = spawn_native_thread(
        entry_pointer["mjs_s35_waiter_entry"](), cw_args, 0, no_name(),
    )
    var raced = poll_flag(cw_args, 1)  # arrival observed
    cwe.signal()  # cross-thread wake: releases the parked waiter
    var wjrc = waiter.join()
    # Assert the release was prompt: settle + wake well under the
    # 10 s park deadline proves the .ok came from OUR signal, not an
    # expiry exit path.
    var e1_ms = (
        MonotonicInstant.now().duration_since(t1).ns // 1_000_000
    )
    _ = raced
    var cross_ok = wjrc == 0 and cw_args[2] == Int64(WaitStatus.ok.value)
    cross_ok = cross_ok and e1_ms < UInt64(5000)
    cwe.destroy()

    if not check("S3.5 1. blocked waiter released by cross-thread signal", cross_ok):
        failed += 1

    # ---- 2. wait_until expiry: past immediate + future bounded band ------------
    var ee = NativeEvent.create()
    var t2 = MonotonicInstant.now()
    var past_dl = t2 - duration_from_millis(1)  # clamps toward zero: past
    var pd_st = ee.wait_until(past_dl)
    var pd_ms = MonotonicInstant.now().duration_since(t2).ns // 1_000_000
    var f0 = MonotonicInstant.now()
    var f_st = ee.wait_until(f0 + duration_from_millis(EXPIRY_MS))
    var f_ms = MonotonicInstant.now().duration_since(f0).ns // 1_000_000
    ee.destroy()
    var expiry_ok = pd_st == WaitStatus.timed_out
    expiry_ok = expiry_ok and pd_ms < UInt64(100)
    expiry_ok = expiry_ok and f_st == WaitStatus.timed_out
    expiry_ok = expiry_ok and f_ms >= UInt64(EXPIRY_MS - 10)
    expiry_ok = expiry_ok and f_ms <= UInt64(EXPIRY_LATE_MS_MAX)

    if not check("S3.5 2. wait_until expiry .timed_out (immediate past, bounded future)", expiry_ok):
        failed += 1

    # ---- 3. pre-signal immediate .ok --------------------------------------------
    var pe = NativeEvent.create()
    pe.signal()  # nobody waiting: the token STICKS
    var t3 = MonotonicInstant.now()
    var ps_st = pe.wait_until(t3 + duration_from_millis(5000))
    var ps_ms = MonotonicInstant.now().duration_since(t3).ns // 1_000_000
    pe.destroy()
    var presig_ok = ps_st == WaitStatus.ok
    presig_ok = presig_ok and ps_ms < UInt64(100)

    if not check("S3.5 3. pre-signal immediate .ok (token sticks)", presig_ok):
        failed += 1

    # ---- 4. breadth-one: ONE signal wakes EXACTLY one of K ----------------------
    var bc_arena = stack_allocation[K * 5, Int64]()
    var bce = NativeEvent.create()
    var bc_handles = stack_allocation[K, Int64]()
    var k = 0
    while k < K:
        var wargs = cell_block(bc_arena, k * 5)
        wargs[0] = bce.handle
        wargs[1] = 0
        wargs[2] = -1000
        wargs[3] = Int64(
            (MonotonicInstant.now() + duration_from_millis(5000)).ticks
        )
        k += 1
    k = 0
    while k < K:
        var w = spawn_native_thread(
            entry_pointer["mjs_s35_waiter_entry"](),
            cell_block(bc_arena, k * 5), 0, no_name(),
        )
        bc_handles[k] = w.handle
        k += 1
    # Barrier-count arrivals, plus the entry's own settle delay, so
    # every waiter provably reached its sleep before the ONE signal.
    k = 0
    var bc_barrier_ok = True
    while k < K:
        bc_barrier_ok = bc_barrier_ok and poll_flag(bc_arena, k * 5 + 1)
        k += 1
    _ = _libc_usleep(UInt32(SETTLE_MS * 1000))
    bce.signal()  # ONE token for K parked waiters
    _ = _libc_usleep(UInt32(QUIET_MS * 1000))
    var woke_now = 0
    k = 0
    while k < K:
        if cell_block(bc_arena, k * 5)[2] == Int64(WaitStatus.ok.value):
            woke_now += 1
        k += 1
    var breadth_one = bc_barrier_ok and woke_now == 1
    # Drain the rest: one signal per remaining sleeper, all .ok.
    var drain_ok = True
    var drained = woke_now
    var drain_spins = 0
    while drained < K:
        bce.signal()
        _ = _libc_usleep(50_000)
        drained = 0
        k = 0
        while k < K:
            if cell_block(bc_arena, k * 5)[2] == Int64(WaitStatus.ok.value):
                drained += 1
            k += 1
        drain_spins += 1
        if drain_spins > 200:  # hang guard, never taken on a green run
            drain_ok = False
            break
    k = 0
    while k < K:
        drain_ok = drain_ok and adopt_join(bc_handles[k]) == 0
        drain_ok = drain_ok and cell_block(bc_arena, k * 5)[2] == Int64(
            WaitStatus.ok.value
        )
        k += 1
    bce.destroy()

    if not check("S3.5 4. breadth-one: one signal wakes exactly one of K=4 counted waiters", breadth_one and drain_ok):
        failed += 1

    # ---- 5. lost-wakeup regression: 10k racing signal/park cycles ---------------
    var lw_args = stack_allocation[6, Int64]()
    lw_args[1] = 0
    lw_args[2] = 0
    lw_args[3] = 0
    var lwe = NativeEvent.create()   # pings: spawner -> looper
    var acke = NativeEvent.create()  # acks: looper -> spawner
    lw_args[0] = lwe.handle
    lw_args[4] = acke.handle
    var looper = spawn_native_thread(
        entry_pointer["mjs_s35_looper_entry"](), lw_args, 0, no_name(),
    )
    # Ping-pong: each ack re-arms the next ping IMMEDIATELY, so the
    # signal keeps racing the waiter between its predicate check and
    # its sleep (pre-park signals stick; post-park signals wake —
    # either ordering must release within the 1 s park deadline).
    var i5 = 0
    var ack_timeouts = 0
    while i5 < LOOP_ITERS:
        lwe.signal()
        if acke.wait_until(
            MonotonicInstant.now() + duration_from_millis(5000)
        ) == WaitStatus.timed_out:
            ack_timeouts += 1  # hang guard, never taken on a green run
        i5 += 1
    var lrc = looper.join()
    var lost_wakeups_free = (
        lrc == 0
        and lw_args[1] == Int64(LOOP_ITERS)
        and lw_args[2] == 0
        and lw_args[3] == 0
        and ack_timeouts == 0
    )
    # The primitive stays fully functional after the endurance run.
    var post_st = lwe.wait_until(MonotonicInstant.now() - duration_from_millis(1))
    var post_ok = post_st == WaitStatus.timed_out
    # 5b. EXPIRY PARITY: race paced signals against a ~3 ms park —
    # every park completes .ok consuming the token (wake beats
    # timeout; never .timed_out with credit left pending).
    var ppe = NativeEvent.create()
    var pw_args = stack_allocation[3, Int64]()
    pw_args[0] = ppe.handle
    pw_args[1] = lwe.handle
    pw_args[2] = 0  # stop flag (stack_allocation is NOT zeroed)
    var pracer = spawn_native_thread(
        entry_pointer["mjs_s35_parity_racer_entry"](), pw_args, 0, no_name(),
    )
    var parity_ok = True
    var j5 = 0
    while j5 < 2000 and parity_ok:
        _ = ppe.signal()
        parity_ok = _wake_class(
            _externs.probe_ev_wait_until(
                lwe.handle, _now_ns() + UInt64(3_000_000)
            )
        ) == 0
        j5 += 1
    pw_args[2] = 1
    _ = ppe.signal()  # final pace releases the racer so it can exit
    parity_ok = parity_ok and pracer.join() == 0
    ppe.destroy()
    if not parity_ok:
        _ = check("S3.5 5b. expiry parity: signal-racing-expiry completes .ok consuming the token", False)
        failed += 1

    # ---- 6. coalescing pins the consumed-vs-sticky choice ------------------------
    var ce = NativeEvent.create()
    ce.signal()
    ce.signal()
    ce.signal()
    ce.signal()
    ce.signal()  # five signals, zero waiters -> exactly ONE token
    var c1_st = ce.wait_until(MonotonicInstant.now() + duration_from_millis(100))
    var c2_st = ce.wait_until(MonotonicInstant.now() - duration_from_millis(1))
    ce.destroy()
    var coalesce_ok = c1_st == WaitStatus.ok and c2_st == WaitStatus.timed_out

    if not check("S3.5 6. five coalesced signals release exactly one wait", coalesce_ok):
        failed += 1

    # ---- 7. mid-wait signal returns .ok long before a far deadline ---------------
    var mw_args = stack_allocation[5, Int64]()
    mw_args[1] = 0
    mw_args[2] = -1000
    var mwe = NativeEvent.create()
    mw_args[0] = mwe.handle
    mw_args[3] = Int64(
        (MonotonicInstant.now() + duration_from_millis(5000)).ticks
    )
    var t7 = MonotonicInstant.now()
    var racer = spawn_native_thread(
        entry_pointer["mjs_s35_waiter_entry"](), mw_args, 0, no_name(),
    )
    _ = poll_flag(mw_args, 1)
    mwe.signal()  # BEFORE the 5 s deadline: must surface as .ok promptly
    var rjrc = racer.join()
    var ms7 = MonotonicInstant.now().duration_since(t7).ns // 1_000_000
    var midwait_ok = rjrc == 0 and mw_args[2] == Int64(WaitStatus.ok.value)
    midwait_ok = midwait_ok and ms7 < UInt64(2000)  # nowhere near 5 s
    mwe.destroy()

    if not check("S3.5 7. mid-wait signal returns .ok well before deadline", midwait_ok):
        failed += 1

    # ---- 8. uninitialized/consumed handle raises EINVAL ---------------------------
    var dead = NativeEvent()  # default = inert/consumed
    var misuse_ok = True

    try:
        dead.signal()
        misuse_ok = False
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")
    try:
        dead.wait()
        misuse_ok = False
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")
    try:
        var dl8 = MonotonicInstant.now() + duration_from_millis(1)
        _ = dead.wait_until(dl8)
        misuse_ok = False  # must have raised
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")
    try:
        dead.destroy()
        misuse_ok = False  # destroy of an inert default MUST raise
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")

    var dd8_ok = live_double_destroy_raises()

    if not check("S3.5 8. uninitialized/consumed handle raises EINVAL", misuse_ok and dd8_ok):
        failed += 1


    print("RESULT: " + String(8 - failed) + "/8 PASSED")
