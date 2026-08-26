# mojito-sys S3.7 — NativeSemaphore conformance (issue #106, spec §14/§17).
#
# Drives the §17 semaphore surface (Mojo wrapper bound to the frozen
# mjs_sem_* C ABI, native/include/mojito_sys.h s3-sem block) across
# real OS threads, pinning PERMIT-ACCOUNTING semantics (the S3.6 leg
# recorded DEFERRED in tests/s3/sync/integration until this lane):
#
#   1. blocked waiter released by a CROSS-THREAD post (arrival-gated
#     handshake + settle delay, far-deadline park) — returns .ok well
#     before the deadline;
#   2. wait_until expiry: past deadline -> .timed_out IMMEDIATELY;
#     future deadline expires ~on time within a bounded tolerance band;
#   3. pre-post immediate .ok — a post with nobody waiting leaves one
#     permit that makes exactly ONE later wait complete without
#     blocking (measured < 100 ms);
#   4. MULTI-PERMIT accumulation (the semaphore-vs-event distinction):
#     N=5 posts with no waiter leave FIVE permits, so exactly N later
#     waits complete .ok and the (N+1)-th blocks then times out — a
#     counting semaphore, NOT NativeEvent's coalescing signal;
#   5. P/V BALANCE across threads: P=7 posts from a poster thread,
#     K=7 consumer threads, each acquires exactly ONE permit; after
#     the K waits a try_wait finds the semaphore depleted — permits
#     are conserved (never lost, never double-consumed);
#   6. try_wait NON-BLOCKING: empty semaphore -> False immediately,
#     post -> True, exhausted -> False again, all prompt (measured);
#   7. NO-NEGATIVE / OVER-ACQUIRE: a semaphore with ONE permit and TWO
#     waiters lets exactly one acquire; the over-acquirer BLOCKS and
#     times out rather than forcing the count below zero;
#   8. -errno misuse: every method on an uninitialized/consumed handle
#     raises the decoded -EINVAL without re-entering C (double destroy
#     included).
#
# PERMIT-ACCOUNTING CONTRACT (normative, mojito_sys/sync/semaphore.mojo
# head): a counting semaphore keeps a non-negative permit count.
# post() increments the count and wakes at most one waiter; wait()
# blocks until the count is positive, then decrements it; try_wait()
# acquires without blocking (-EBUSY status when empty). Permits are
# conserved across posts and waits — the count never underflows below
# zero and a permit is consumed by exactly one wait.
#
# b2 notes (verbatim discipline from tests/s3/sync/{event,condvar}/
# conformance.mojo):
#   - Thread entries are @export abi("C") defs whose addresses are
#     materialized by the entry_pointer[symbol]() adrp/add idiom; they
#     drive the SCALAR PROBE SHIMS only (no aggregate-returning wrapper
#     calls inside an @export frame) and decode raw rcs into cells with
#     CONSTANT cell indices.
#   - Wrapper methods (wait, wait_until, try_wait, post, destroy) are
#     exercised from MAIN scope only (crash workaround 2, condvar lane).
#   - Failure assertions decode through raise_errno (`String(e)` carries
#     the errno spelling); failures accumulate in a main()-local counter.
#
# Run via tests/s3/sync/semaphore/run.sh (builds libmojito_sys.dylib
# first); green requires the exact "RESULT: 8/8 PASSED" line.
from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

from mojito_sys.sync.semaphore import NativeSemaphore
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

# Breadth/multi-permit shapes.
comptime K = 4

# Multi-permit accumulation: N posts -> N later waits (no coalescing).
comptime MULTI = 5

# P/V balance: poster issues P permits, P consumers each take one.
comptime P = 7

# Quiet-period / tolerance margins (CI-safe, still meaningful).
comptime SETTLE_MS = 120
comptime QUIET_MS = 250
comptime EXPIRY_MS = 120
comptime EXPIRY_LATE_MS_MAX = 900
comptime OVER_DL_MS = 500


# ---- shared helpers ----------------------------------------------------------

@extern("usleep")
def _libc_usleep(useconds: UInt32) abi("C") -> Int32:
    ...


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven in tests/s3/sync/{mutex,condvar,event}/
# conformance.mojo.
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
# mirroring NativeThread/NativeEvent conformance usage).
def adopt_join(handle: Int64) raises -> Int64:
    var w = NativeThread()
    w.handle = handle
    w.consumed = False
    return w.join()


# Poll a shared cell until it turns nonzero (plain cell read; the
# mutex/condvar handoff inside the semaphore makes a pre-settling post
# SAFE — it accumulates as a permit for a later wait). Hang-guarded:
# False after ~10 s, never taken on a green run.
def poll_flag(cell: CellsPtr, idx: Int) -> Bool:
    var spins = 0
    while True:
        if cell[idx] != 0:
            return True
        _ = _libc_usleep(200)
        spins += 1
        if spins > 50_000:
            return False


# Decode a raw mjs_sem_wait_until rc into the WaitStatus tag space:
# 0 = .ok (permit consumed), 1 = .timed_out, -1 = unexpected error.
def _wait_class(rc: Int32) -> Int64:
    var et = Int32(-110)
    if CompilationTarget().is_macos():
        et = Int32(-60)
    if rc == 0:
        return Int64(0)
    if rc == et:
        return Int64(1)
    return Int64(-1)


# ---- 1/7. gated waiter thread ------------------------------------------------
# ud layout: [0]=sem handle [1]=arrived flag [2]=wake status tag
#            (-1000 pending; 0/.ok, 1/.timed_out, -1/error after)
#            [3]=ABSOLUTE monotonic deadline in ns (precomputed by the
#            spawner; keeps this export free of clock calls)
@export("mjs_s37_waiter_entry")
def _waiter_entry(ud: CellsPtr) abi("C") -> Int64:
    # Scalar probes only inside the @export frame (b2 workaround, see
    # module head); the status travels back as a plain tag.
    ud[1] = 1
    _ = _libc_usleep(UInt32(SETTLE_MS * 1000))  # reach the sleep
    ud[2] = _wait_class(
        _externs.probe_sem_wait_until(ud[0], UInt64(ud[3]))
    )
    return 0


# ---- 5. P/V balance: poster thread -------------------------------------------
# ud layout: [0]=sem handle [1]=permits to post [2]=done flag
@export("mjs_s37_poster_entry")
def _poster_entry(ud: CellsPtr) abi("C") -> Int64:
    var n = Int(ud[1])
    var i = 0
    while i < n:
        if _externs.probe_sem_post(ud[0]) != 0:
            return -1
        i += 1
    ud[2] = 1
    return 0


# Double-destroy probe on a LIVE handle: first destroy consumes, the
# second MUST raise the decoded -EINVAL. Isolated helper returning a
# plain Bool (b2-safe shape, mirrors the condvar lane).
def live_double_destroy_raises() raises -> Bool:
    var s = NativeSemaphore.create(0)
    s.destroy()
    try:
        s.destroy()
        return False  # second destroy MUST have raised
    except e:
        return contains(String(e), "EINVAL")


def main() raises:
    var failed = 0

    # ---- 1. blocked waiter released by cross-thread post --------------------
    var cw_args = stack_allocation[5, Int64]()
    cw_args[1] = 0
    cw_args[2] = -1000  # pending marker (distinct from any status tag)
    var cws = NativeSemaphore.create(0)
    cw_args[0] = cws.handle
    cw_args[3] = Int64(
        (MonotonicInstant.now() + duration_from_millis(10000)).ticks
    )
    var t1 = MonotonicInstant.now()
    var waiter = spawn_native_thread(
        entry_pointer["mjs_s37_waiter_entry"](), cw_args, 0, no_name(),
    )
    var raced = poll_flag(cw_args, 1)  # arrival observed
    cws.post()  # cross-thread release: grants one permit to the waited
    var wjrc = waiter.join()
    var e1_ms = (
        MonotonicInstant.now().duration_since(t1).ns // 1_000_000
    )
    _ = raced
    var cross_ok = wjrc == 0 and cw_args[2] == Int64(WaitStatus.ok.value)
    cross_ok = cross_ok and e1_ms < UInt64(5000)
    cws.destroy()

    if not check("S3.7 1. blocked waiter released by cross-thread post", cross_ok):
        failed += 1

    # ---- 2. wait_until expiry: past immediate + future bounded band -----------
    var es = NativeSemaphore.create(0)
    var t2 = MonotonicInstant.now()
    var past_dl = t2 - duration_from_millis(1)  # clamps toward zero: past
    var pd_st = es.wait_until(past_dl)
    var pd_ms = MonotonicInstant.now().duration_since(t2).ns // 1_000_000
    var f0 = MonotonicInstant.now()
    var f_st = es.wait_until(f0 + duration_from_millis(EXPIRY_MS))
    var f_ms = MonotonicInstant.now().duration_since(f0).ns // 1_000_000
    es.destroy()
    var expiry_ok = pd_st == WaitStatus.timed_out
    expiry_ok = expiry_ok and pd_ms < UInt64(100)
    expiry_ok = expiry_ok and f_st == WaitStatus.timed_out
    expiry_ok = expiry_ok and f_ms >= UInt64(EXPIRY_MS - 10)
    expiry_ok = expiry_ok and f_ms <= UInt64(EXPIRY_LATE_MS_MAX)

    if not check("S3.7 2. wait_until expiry .timed_out (immediate past, bounded future)", expiry_ok):
        failed += 1

    # ---- 3. pre-post immediate .ok (one permit sticks) ------------------------
    var ps = NativeSemaphore.create(0)
    ps.post()  # nobody waiting: one permit remains
    var t3 = MonotonicInstant.now()
    var p_st = ps.wait_until(t3 + duration_from_millis(5000))
    var p_ms = MonotonicInstant.now().duration_since(t3).ns // 1_000_000
    ps.destroy()
    var presig_ok = p_st == WaitStatus.ok
    presig_ok = presig_ok and p_ms < UInt64(100)

    if not check("S3.7 3. pre-post immediate .ok (one permit sticks)", presig_ok):
        failed += 1

    # ---- 4. MULTI-PERMIT accumulation: N posts -> exactly N waits -------------
    var ms = NativeSemaphore.create(0)
    var m = 0
    while m < MULTI:
        ms.post()  # permits ACCUMULATE (counting semaphore, no coalescing)
        m += 1
    var multi_ok = True
    m = 0
    var m0 = MonotonicInstant.now()
    while m < MULTI:
        var st = ms.wait_until(m0 + duration_from_millis(200))
        if st != WaitStatus.ok:
            multi_ok = False
        m += 1
    # The (N+1)-th wait must BLOCK then time out: all permits consumed.
    var over_st = ms.wait_until(MonotonicInstant.now() - duration_from_millis(1))
    var multi_ms = (
        MonotonicInstant.now().duration_since(m0).ns // 1_000_000
    )
    ms.destroy()
    multi_ok = multi_ok and over_st == WaitStatus.timed_out
    multi_ok = multi_ok and multi_ms < UInt64(2000)  # no accidental blocking

    if not check("S3.7 4. multi-permit: " + String(MULTI) + " posts release exactly that many waits (no coalescing)", multi_ok):
        failed += 1

    # ---- 5. P/V balance across threads -----------------------------------------
    var pv_args = stack_allocation[4, Int64]()
    pv_args[1] = Int64(P)  # poster issues exactly P permits
    pv_args[2] = -1000
    var pvs = NativeSemaphore.create(0)
    pv_args[0] = pvs.handle
    pv_args[3] = Int64(
        (MonotonicInstant.now() + duration_from_millis(10000)).ticks
    )
    # K=P consumers, each parks waiting for ONE permit.
    var pv_arena = stack_allocation[P * 5, Int64]()
    var pv_handles = stack_allocation[P, Int64]()
    var p = 0
    while p < P:
        var wargs = cell_block(pv_arena, p * 5)
        wargs[0] = pvs.handle
        wargs[1] = 0
        wargs[2] = -1000
        wargs[3] = Int64(
            (MonotonicInstant.now() + duration_from_millis(10000)).ticks
        )
        p += 1
    p = 0
    while p < P:
        var w = spawn_native_thread(
            entry_pointer["mjs_s37_waiter_entry"](),
            cell_block(pv_arena, p * 5), 0, no_name(),
        )
        pv_handles[p] = w.handle
        p += 1
    # Barrier-count arrivals so every consumer is provably parked.
    var pv_barrier_ok = True
    p = 0
    while p < P:
        pv_barrier_ok = pv_barrier_ok and poll_flag(pv_arena, p * 5 + 1)
        p += 1
    _ = _libc_usleep(UInt32(SETTLE_MS * 1000))
    # Poster issues exactly P permits -> all P consumers complete .ok.
    var poster = spawn_native_thread(
        entry_pointer["mjs_s37_poster_entry"](), pv_args, 0, no_name(),
    )
    var poster_ok = poster.join() == 0 and pv_args[2] == 1
    var pv_ok = pv_barrier_ok
    p = 0
    while p < P:
        pv_ok = pv_ok and adopt_join(pv_handles[p]) == 0
        pv_ok = pv_ok and cell_block(pv_arena, p * 5)[2] == Int64(
            WaitStatus.ok.value
        )
        p += 1
    # Depleted: exactly one try_wait now finds nothing.
    var depleted = not pvs.try_wait()
    pvs.destroy()
    pv_ok = pv_ok and poster_ok and depleted

    if not check("S3.7 5. P/V balance: " + String(P) + " posts hand out exactly one permit each (conserved)", pv_ok):
        failed += 1

    # ---- 6. try_wait NON-BLOCKING ----------------------------------------------
    var ts = NativeSemaphore.create(0)
    var tw0 = MonotonicInstant.now()
    var r0 = ts.try_wait()
    var tw0_ms = MonotonicInstant.now().duration_since(tw0).ns // 1_000_000
    ts.post()
    var tw1 = MonotonicInstant.now()
    var r1 = ts.try_wait()
    var tw1_ms = MonotonicInstant.now().duration_since(tw1).ns // 1_000_000
    var tw2 = MonotonicInstant.now()
    var r2 = ts.try_wait()
    var tw2_ms = MonotonicInstant.now().duration_since(tw2).ns // 1_000_000
    ts.destroy()
    var try_ok = r0 == False and tw0_ms < UInt64(100)
    try_ok = try_ok and r1 == True and tw1_ms < UInt64(100)
    try_ok = try_ok and r2 == False and tw2_ms < UInt64(100)

    if not check("S3.7 6. try_wait non-blocking (empty->False, post->True, exhausted->False)", try_ok):
        failed += 1

    # ---- 7. NO-NEGATIVE / over-acquire: one permit, two waiters ----------------
    var os = NativeSemaphore.create(1)
    var oa = stack_allocation[2 * 5, Int64]()
    var oh = stack_allocation[2, Int64]()
    var o = 0
    var o_dl = Int64(
        (MonotonicInstant.now() + duration_from_millis(OVER_DL_MS)).ticks
    )
    while o < 2:
        var wargs = cell_block(oa, o * 5)
        wargs[0] = os.handle
        wargs[1] = 1
        wargs[2] = -1000
        wargs[3] = o_dl
        var w = spawn_native_thread(
            entry_pointer["mjs_s37_waiter_entry"](),
            cell_block(oa, o * 5), 0, no_name(),
        )
        oh[o] = w.handle
        o += 1
    var over_ok = True
    o = 0
    while o < 2:
        over_ok = over_ok and adopt_join(oh[o]) == 0
        o += 1
    # Exactly one acquired the single permit; the over-acquirer BLOCKED
    # and timed out — the count never dropped below zero.
    var one_ok = 0
    var one_to = 0
    o = 0
    while o < 2:
        var tag = cell_block(oa, o * 5)[2]
        if tag == Int64(WaitStatus.ok.value):
            one_ok += 1
        elif tag == Int64(WaitStatus.timed_out.value):
            one_to += 1
        o += 1
    os.destroy()
    over_ok = over_ok and one_ok == 1 and one_to == 1

    if not check("S3.7 7. no negative permits: single permit, two waiters — one .ok, one blocks & times out", over_ok):
        failed += 1

    # ---- 8. uninitialized/consumed handle raises EINVAL --------------------------
    var dead = NativeSemaphore()  # default = inert/consumed
    var misuse_ok = True

    try:
        dead.post()
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
        _ = dead.try_wait()
        misuse_ok = False  # must have raised
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")
    try:
        dead.destroy()
        misuse_ok = False  # destroy of an inert default MUST raise
    except e:
        misuse_ok = misuse_ok and contains(String(e), "EINVAL")

    var dd8_ok = live_double_destroy_raises()

    if not check("S3.7 8. uninitialized/consumed handle raises EINVAL", misuse_ok and dd8_ok):
        failed += 1


    print("RESULT: " + String(8 - failed) + "/8 PASSED")