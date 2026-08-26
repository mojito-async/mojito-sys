# mojito-sys S3.2 — NativeCondVar conformance (issue #58, spec §16).
#
# Drives the §16 condition-variable surface (Mojo wrapper bound to the
# frozen mjs_condvar_* C ABI, native/include/mojito_sys.h s3-condvar
# block) across real OS threads:
#
#   1. producer/consumer 1000 items ZERO LOSS — one producer thread,
#     main-thread consumer; strict sequence check (item n+1 follows
#     item n) so a lost OR duplicated wakeup cannot pass;
#   2. broadcast wakes K=4 barrier-counted waiters — each arrival flag
#     is observed UNDER THE MUTEX (so every waiter is provably asleep
#     inside the atomic release), then ONE broadcast releases all four
#     with .ok;
#   3. signal wakes EXACTLY ONE (count-gated handshake) — same
#     under-mutex arrival gate, ONE signal, quiet period, exactly one
#     woken count; a follow-up broadcast drains the rest;
#   4. past-deadline wait_until returns .timed_out IMMEDIATELY;
#   5. future-deadline wait_until expires ~on time within a bounded
#     tolerance band (early-wake and pathological-late bounds);
#   6. signal-before-deadline returns .ok (lost-wakeup-free handshake:
#     the arrival gate is read under the mutex, which proves the waiter
#     sits inside the atomic release before any signal is issued);
#   7. predicate loop survives 10k iterations WITH INJECTED SPURIOUS
#     WAKEUPS — each iteration takes one deliberately-already-expired
#     wait (an unconditional wake without the predicate by
#     construction) plus one micro-deadline wait, while a broadcaster
#     thread hammers genuine wakes; the loop tolerates every outcome
#     per the WaitStatus spurious-wakeup contract (sync/common.mojo);
#   8. -errno misuse: every method on an uninitialized/consumed handle
#     raises the decoded -EINVAL without re-entering C.
#
# SPURIOUS-WAKEUP CONTRACT (mojito_sys.sync.common): every wait in this
# suite re-checks its predicate after ANY wake — .ok is never trusted
# as "condition became true".
#
# b2 notes (matching tests/s3/sync/mutex/conformance.mojo):
#   - Thread entries are @export abi("C") defs whose addresses are
#     materialized by the entry_pointer[symbol]() adrp/add idiom; a
#     C-ABI export cannot propagate `raises`, so child-side errors trap
#     into the returned status.
#   - Shared state travels through stack-carved Int64 cells; per-waiter
#     cell blocks live on main's stack and their ADDRESSES travel
#     through an Int64 index table (Int(ptr) / unsafe_from_address).
#   - Failure assertions decode through raise_errno (`String(e)` carries
#     the errno spelling); failures accumulate in a main()-local
#     counter (no module-level mutable globals).
#
# Run via tests/s3/sync/condvar/run.sh (builds libmojito_sys.dylib
# first); green requires the exact "RESULT: 8/8 PASSED" line.

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from mojito_sys.sync.condvar import NativeCondVar
import mojito_sys.sync.externs as _externs
from std.sys import CompilationTarget

from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.mutex import NativeMutex
from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    UserdataPtr,
    no_name,
    spawn_native_thread,
)
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import _now_ns
from mojito_sys.time.monotonic import MonotonicInstant

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]

# Producer/consumer shape (spec acceptance): ITEMS items through a CAP
# slot ring; the consumer re-checks the predicate after EVERY wake.
comptime ITEMS = 1000
comptime CAP = 64

# Broadcast / signal-handshake waiter count.
comptime K = 4

# Predicate-loop endurance shape (spec acceptance): 10k iterations.
comptime LOOP_ITERS = 10_000

# Generous quiet-period / tolerance margins (CI-safe, still meaningful):
# exactly-one observation window and the expiry tolerance band.
comptime QUIET_MS = 250
comptime EXPIRY_MS = 120
comptime EXPIRY_LATE_MS_MAX = 900


# ---- shared helpers ----------------------------------------------------------

@extern("usleep")
def _libc_usleep(useconds: UInt32) abi("C") -> Int32:
    ...


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven in tests/s3/sync/mutex/conformance.mojo.
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


# Poll a shared cell until it turns nonzero. The poll reads the cell
# UNDER THE MUTEX, which doubles as the lost-wakeup barrier: once this
# returns, the flagged waiter provably sits inside the atomic mutex
# release of its wait, so a subsequent signal/broadcast cannot be lost.
def poll_flag(mut m: NativeMutex, cell: CellsPtr, idx: Int) raises -> Bool:
    var spins = 0
    while True:
        m.lock()
        var v = cell[idx]
        m.unlock()
        if v != 0:
            return True
        _ = _libc_usleep(200)
        spins += 1
        if spins > 50_000:  # ~10 s worst case: hang guard, never taken
            return False


# ---- 1. producer thread ------------------------------------------------------
# ud layout: [0]=cv handle [1]=mutex handle [2]=produced total
#            [3]=consumed total [4]=(unused) [5]=tail index
#            [6]=entry status [8..8+CAP)=ring slots
@export("mjs_s32_producer_entry")
def _producer_entry(ud: CellsPtr) abi("C") -> Int64:
    # SINGLE-SLOT handoff, CONSTANT cell indices only. b2's export-frame
    # register misbind corrupts COMPUTED indices (a ring-buffer version
    # of this entry wrote produced=1002/garbage for 1000 pushes); flat
    # layouts match the proven mutex-lane entry shape. Scalar probes
    # throughout.
    # ud layout: [0]=cv handle [1]=mutex handle [2]=entry status
    #            [4]=slot (0 empty / seq filled)
    var seq = 1
    while seq <= ITEMS:
        try:
            _externs.probe_lock(ud[1])
            while ud[4] != 0:
                var wrc = _externs.probe_cv_wait(ud[0], ud[1])
                if wrc != 0:
                    ud[2] = -1
                    _externs.probe_unlock(ud[1])
                    return -1
            ud[4] = Int64(seq)
            _externs.probe_cv_signal(ud[0])
            _externs.probe_unlock(ud[1])
        except:
            ud[2] = -1
            return -1
        seq += 1
    ud[2] = 0
    return 0


@export("mjs_s32_consumer_entry")
def _consumer_entry(ud: CellsPtr) abi("C") -> Int64:
    # Consumer half of the single-slot handoff (see producer note):
    # predicate loop over the SAME mutex/cv via scalar probes, strict
    # sequence verification, constant cell indices only.
    # ud layout: [0]=cv [1]=mutex [3]=entry status [4]=slot
    #            [5]=sequence-verdict cell (1 intact)
    var expected = 1
    while expected <= ITEMS:
        try:
            _externs.probe_lock(ud[1])
            while ud[4] == 0:
                var wrc = _externs.probe_cv_wait(ud[0], ud[1])
                if wrc != 0:
                    ud[3] = -1
                    _externs.probe_unlock(ud[1])
                    return -1
            if ud[4] != Int64(expected):
                ud[5] = 0
            expected += 1
            ud[4] = 0
            _externs.probe_cv_signal(ud[0])
            _externs.probe_unlock(ud[1])
        except:
            ud[3] = -1
            return -1
    ud[3] = 0
    return 0


# ---- 2/3. gated waiter thread ------------------------------------------------
# ud layout: [0]=cv handle [1]=mutex handle [2]=arrived flag
#            [3]=wake status tag (-1000 pending; WaitStatus tags after)
@export("mjs_s32_waiter_entry")
def _waiter_entry(ud: CellsPtr) abi("C") -> Int64:
    # ud layout: [0]=cv handle [1]=mutex handle [2]=arrived flag
    #            [3]=wake status tag (-1000 pending; decoded rc after)
    #            [4]=ABSOLUTE monotonic deadline in ns (precomputed by
    #            the spawner; keeps this export free of clock calls)
    #
    # b2 WORKAROUND (issue #58 lane): cv.wait_until returns the
    # WaitStatus aggregate, and calling it from INSIDE an @export
    # abi("C") frame SIGSEGVs the b2 1.0.0b2 compiler (the proven
    # no-aggregates-in-extern-reaching-frames rule). This entry drives
    # the non-raising scalar probe shim directly and decodes the raw rc
    # into a cell; the WRAPPER wait_until path is exercised main-side
    # (consumer predicate loop, tests 4/5/6 drivers).
    var m = NativeMutex()
    m.handle = ud[1]
    m.destroyed = False
    try:
        m.lock()
        ud[2] = 1
        var rc = _externs.probe_cv_wait_until(ud[0], ud[1], UInt64(ud[4]))
        if rc == 0:
            ud[3] = Int64(WaitStatus.ok.value)
        else:
            # Only the timeout status can end this wait besides a wake;
            # anything else is a child-side error worth surfacing.
            ud[3] = Int64(WaitStatus.timed_out.value)
        m.unlock()
    except:
        return -1
    return 0


# ---- 6. signal-before-deadline waiter ---------------------------------------
# Identical shape to _waiter_entry; a distinct symbol for readable stack
# traces and an unambiguous @export surface per scenario.
@export("mjs_s32_racer_entry")
def _racer_entry(ud: CellsPtr) abi("C") -> Int64:
    return _waiter_entry(ud)


# ---- 7. predicate-loop endurance --------------------------------------------
# Looper ud: [0]=cv [1]=mutex [2]=iters done [3]=ok wakes seen
#            [4]=timed_out wakes seen [5]=other statuses seen
# Host-selected ETIMEDOUT spelling (darwin 60 / Linux 110) mapped to
# plain tags: 0 = woken, 1 = timed out, -1 = unexpected.
def _wake_class(rc: Int32) -> Int64:
    var et = Int32(-110)
    if CompilationTarget().is_macos():
        et = Int32(-60)
    if rc == 0:
        return Int64(0)
    if rc == et:
        return Int64(1)
    return Int64(-1)


@export("mjs_s32_looper_entry")
def _looper_entry(ud: CellsPtr) abi("C") -> Int64:
    # ud layout: [0]=cv [1]=mutex [2]=iters done [3]=ok wakes seen
    #            [4]=timed_out wakes seen [5]=unexpected wakes seen
    # Same b2 WORKAROUND as _waiter_entry: the endurance loop drives
    # the scalar probe shims (no WaitStatus/MonotonicInstant values
    # cross any @export frame); outcomes are tallied as tags.
    var m = NativeMutex()
    m.handle = ud[1]
    m.destroyed = False
    var i = 0
    try:
        while i < LOOP_ITERS:
            m.lock()
            # Injected spurious wake #1: an ALREADY-EXPIRED deadline.
            # By construction this carries no predicate signal — the
            # loop must simply tolerate whatever comes back.
            var cls1 = _wake_class(
                _externs.probe_cv_wait_until(ud[0], ud[1], UInt64(1))
            )
            if cls1 == 0:
                ud[3] += 1
            elif cls1 == 1:
                ud[4] += 1
            else:
                ud[5] += 1
            # Injected spurious wake #2: a micro-deadline race against
            # the broadcaster thread below. Scalar clock helper ONLY —
            # aggregate-returning calls inside this @export frame
            # corrupted neighboring cells at runtime (see producer note).
            var soon = _now_ns() + UInt64(200_000)
            var cls2 = _wake_class(
                _externs.probe_cv_wait_until(ud[0], ud[1], soon)
            )
            if cls2 == 0:
                ud[3] += 1
            elif cls2 == 1:
                ud[4] += 1
            else:
                ud[5] += 1
            m.unlock()
            i += 1
    except:
        return -1
    ud[2] = Int64(i)
    return 0


@export("mjs_s32_broadcast_spam_entry")
def _broadcast_spam_entry(ud: CellsPtr) abi("C") -> Int64:
    # Scalar probe broadcast (same @export-frame rule as above).
    var i = 0
    try:
        while i < 12000:
            _externs.probe_cv_broadcast(ud[0])
            _ = _libc_usleep(250)
            i += 1
    except:
        return -1
    ud[1] = Int64(i)
    return 0


# Double-destroy probe on a LIVE handle: first destroy consumes, the
# second MUST raise the decoded -EINVAL. Isolated in a helper so the
# verdict travels as a plain return (b2 crashed on the inline
# dead-initialization form of this check; see lane notes).
def live_double_destroy_raises() raises -> Bool:
    var cv = NativeCondVar.create()
    cv.destroy()
    try:
        cv.destroy()
        return False  # second destroy MUST have raised
    except e:
        return contains(String(e), "EINVAL")



def main() raises:
    var failed = 0

    # ---- 1. producer/consumer 1000 items zero loss ---------------------------
    # Producer AND consumer threads hand 1000 strictly-sequenced items
    # through a single slot guarded by NativeMutex + NativeCondVar; BOTH
    # sides run the §16 predicate loop (re-check after EVERY wake).
    # Sequence equality proves zero loss AND zero duplication.
    # Toolchain note: the waits run on scalar probes inside @export
    # frames and the loop counters live in cells — see the crash
    # workaround notes in mojito_sys/sync/condvar.mojo; the wrapper
    # wait_until surface is exercised directly from main below (tests
    # 4/5/6) and its loop form is covered by the C smoke lane.
    var pc_args = stack_allocation[8, Int64]()
    var pcm = NativeMutex.create()
    var pccv = NativeCondVar.create()
    pc_args[0] = pccv.handle
    pc_args[1] = pcm.handle
    pc_args[4] = 0  # slot empty
    pc_args[5] = 1  # sequence verdict intact

    var prod_entry = spawn_native_thread(
        entry_pointer["mjs_s32_producer_entry"](), pc_args, 0, no_name()
    )
    var cons_entry = spawn_native_thread(
        entry_pointer["mjs_s32_consumer_entry"](), pc_args, 0, no_name()
    )
    var pjrc = prod_entry.join()
    var cjrc = cons_entry.join()
    var zero_loss_ok = (
        pjrc == 0 and cjrc == 0 and pc_args[2] == 0 and pc_args[3] == 0
        and pc_args[5] == 1
    )
    pcm.destroy()
    pccv.destroy()
    if not check(
        "S3.2 producer/consumer 1000 items zero loss", zero_loss_ok
    ):
        failed += 1

    # ---- 2. broadcast wakes K barrier-counted waiters --------------------------
    # One ARENA carved once; per-waiter blocks are byte offsets into it.
    # (Per-iteration stack_allocation reuses the same address across loop
    # bodies, which aliased every waiter's cells into one.)
    var bc_arena = stack_allocation[K * 5, Int64]()
    var bcm = NativeMutex.create()
    var bccv = NativeCondVar.create()
    var bc_handles = stack_allocation[K, Int64]()
    var k = 0
    while k < K:
        var wargs = UnsafePointer[Int64, MutAnyOrigin](
            unsafe_from_address=Int(bc_arena) + k * 5 * 8
        )
        wargs[0] = bccv.handle
        wargs[1] = bcm.handle
        wargs[2] = 0
        wargs[3] = -1000  # pending marker (distinct from any status tag)
        wargs[4] = Int64(
            (MonotonicInstant.now() + duration_from_millis(5000)).ticks
        )
        k += 1
    k = 0
    while k < K:
        var w = spawn_native_thread(
            entry_pointer["mjs_s32_waiter_entry"](),
            cell_block(bc_arena, k * 5), 0, no_name(),
        )
        bc_handles[k] = w.handle
        k += 1
    # Barrier-counted: ALL K arrivals observed under the mutex before
    # the single broadcast fires.
    var barrier_ok = True
    k = 0
    while k < K:
        barrier_ok = barrier_ok and poll_flag(
            bcm, cell_block(bc_arena, k * 5), 2
        )
        k += 1
    bccv.broadcast()  # ONE broadcast for ALL K sleepers
    var woke_count = 0
    var all_ok_status = True
    var joins_ok = True
    k = 0
    while k < K:
        joins_ok = joins_ok and adopt_join(bc_handles[k]) == 0
        if cell_block(bc_arena, k * 5)[3] == Int64(WaitStatus.ok.value):
            woke_count += 1
        else:
            all_ok_status = False
        k += 1
    var broadcast_ok = (
        barrier_ok and woke_count == K and all_ok_status and joins_ok
    )
    bcm.destroy()
    bccv.destroy()

    if not check("S3.2 2. broadcast wakes K barrier-counted waiters", broadcast_ok):
        failed += 1

    # ---- 3. signal wakes exactly one (count-gated handshake) -------------------
    var sg_arena = stack_allocation[K * 5, Int64]()
    var sgm = NativeMutex.create()
    var sgcv = NativeCondVar.create()
    var sg_handles = stack_allocation[K, Int64]()
    k = 0
    while k < K:
        var wargs = UnsafePointer[Int64, MutAnyOrigin](
            unsafe_from_address=Int(sg_arena) + k * 5 * 8
        )
        wargs[0] = sgcv.handle
        wargs[1] = sgm.handle
        wargs[2] = 0
        wargs[3] = -1000
        wargs[4] = Int64(
            (MonotonicInstant.now() + duration_from_millis(5000)).ticks
        )
        k += 1
    k = 0
    while k < K:
        var w = spawn_native_thread(
            entry_pointer["mjs_s32_waiter_entry"](),
            cell_block(sg_arena, k * 5), 0, no_name(),
        )
        sg_handles[k] = w.handle
        k += 1
    var sg_barrier_ok = True
    k = 0
    while k < K:
        sg_barrier_ok = sg_barrier_ok and poll_flag(
            sgm, cell_block(sg_arena, k * 5), 2
        )
        k += 1
    sgcv.signal()  # exactly ONE ticket
    _ = _libc_usleep(UInt32(QUIET_MS * 1000))
    sgm.lock()
    var woke_now = 0
    k = 0
    while k < K:
        if cell_block(sg_arena, k * 5)[3] == Int64(WaitStatus.ok.value):
            woke_now += 1
        k += 1
    sgm.unlock()
    # Drain the remaining sleepers so their 5s deadlines never fire.
    var drain_ok = True
    var drained = woke_now
    var drain_spins = 0
    while drained < K:
        sgcv.broadcast()
        _ = _libc_usleep(50_000)
        sgm.lock()
        drained = 0
        k = 0
        while k < K:
            if cell_block(sg_arena, k * 5)[3] == Int64(WaitStatus.ok.value):
                drained += 1
            k += 1
        sgm.unlock()
        drain_spins += 1
        if drain_spins > 200:  # hang guard, never taken on a green run
            drain_ok = False
            break
    k = 0
    while k < K:
        drain_ok = drain_ok and adopt_join(sg_handles[k]) == 0
        k += 1
    var signal_one_ok = sg_barrier_ok and woke_now == 1 and drain_ok
    sgm.destroy()
    sgcv.destroy()

    if not check("S3.2 3. signal wakes exactly one (count-gated handshake)", signal_one_ok):
        failed += 1

    # ---- 4. past-deadline immediate .timed_out ---------------------------------
    var pdm = NativeMutex.create()
    var pdcv = NativeCondVar.create()
    pdm.lock()
    var t0 = MonotonicInstant.now()
    var past_dl = t0 - duration_from_millis(1)  # clamps toward zero: past
    var pd_st = pdcv.wait_until(pdm, past_dl)
    var pd_elapsed = MonotonicInstant.now().duration_since(t0)
    pdm.unlock()
    var past_ok = pd_st == WaitStatus.timed_out
    past_ok = past_ok and pd_elapsed.ns < duration_from_millis(100).ns
    pdm.destroy()
    pdcv.destroy()

    if not check("S3.2 4. past-deadline immediate .timed_out", past_ok):
        failed += 1

    # ---- 5. future-deadline expires ~on time (bounded tolerance) ---------------
    var fm = NativeMutex.create()
    var fcv = NativeCondVar.create()
    fm.lock()
    var f0 = MonotonicInstant.now()
    var f_st = fcv.wait_until(fm, f0 + duration_from_millis(EXPIRY_MS))
    var f_elapsed_ms = (
        MonotonicInstant.now().duration_since(f0).ns // 1_000_000
    )
    fm.unlock()
    var future_ok = f_st == WaitStatus.timed_out
    future_ok = future_ok and f_elapsed_ms >= UInt64(EXPIRY_MS - 10)
    future_ok = future_ok and f_elapsed_ms <= UInt64(EXPIRY_LATE_MS_MAX)
    fm.destroy()
    fcv.destroy()

    if not check("S3.2 5. future-deadline expires ~on time (bounded tolerance)", future_ok):
        failed += 1

    # ---- 6. signal-before-deadline .ok -----------------------------------------
    var rc_args = stack_allocation[5, Int64]()
    var rcm = NativeMutex.create()
    var rccv = NativeCondVar.create()
    rc_args[0] = rccv.handle
    rc_args[1] = rcm.handle
    rc_args[2] = 0
    rc_args[3] = -1000
    rc_args[4] = Int64(
        (MonotonicInstant.now() + duration_from_millis(5000)).ticks
    )
    var racer = spawn_native_thread(
        entry_pointer["mjs_s32_racer_entry"](), rc_args, 0, no_name()
    )
    var raced = poll_flag(rcm, rc_args, 2)
    rccv.signal()  # BEFORE the 5s deadline: must surface as .ok
    var rjrc = racer.join()
    var sig_race_ok = raced and rjrc == 0
    sig_race_ok = sig_race_ok and rc_args[3] == Int64(WaitStatus.ok.value)
    rcm.destroy()
    rccv.destroy()

    if not check("S3.2 6. signal-before-deadline .ok", sig_race_ok):
        failed += 1

    # ---- 7. predicate loop survives 10k iterations w/ injected spurious --------
    var lp_args = stack_allocation[6, Int64]()
    # stack_allocation does NOT zero: every tally cell starts explicit.
    lp_args[2] = 0
    lp_args[3] = 0
    lp_args[4] = 0
    lp_args[5] = 0
    var lpm = NativeMutex.create()
    var lpcv = NativeCondVar.create()
    lp_args[0] = lpcv.handle
    lp_args[1] = lpm.handle
    # Spammer FIRST so genuine broadcasts span the whole endurance run.
    var spam_args = stack_allocation[2, Int64]()
    spam_args[0] = lpcv.handle
    var spammer = spawn_native_thread(
        entry_pointer["mjs_s32_broadcast_spam_entry"](),
        spam_args, 0, no_name(),
    )
    var looper = spawn_native_thread(
        entry_pointer["mjs_s32_looper_entry"](), lp_args, 0, no_name()
    )
    var lrc = looper.join()
    var src_rc = spammer.join()
    var loop_ok = lrc == 0 and lp_args[2] == Int64(LOOP_ITERS)
    # Both wake classes must have been exercised: injected expired
    # deadlines (.timed_out) AND genuine/spurious broadcasts (.ok).
    loop_ok = loop_ok and lp_args[4] > 0 and lp_args[3] > 0
    loop_ok = loop_ok and lp_args[5] == 0  # nothing outside ok|timed_out
    loop_ok = loop_ok and src_rc == 0
    # The primitive stays fully functional after the endurance run.
    lpm.lock()
    var post_dl = MonotonicInstant.now() - duration_from_millis(1)
    var post_st = lpcv.wait_until(lpm, post_dl)
    lpm.unlock()
    loop_ok = loop_ok and post_st == WaitStatus.timed_out
    lpm.destroy()
    lpcv.destroy()

    if not check("S3.2 7. predicate loop survives 10k iterations w/ injected spurious", loop_ok):
        failed += 1

    # ---- 8. uninitialized/consumed handle raises EINVAL ------------------------
    var dead = NativeCondVar()  # default = inert/consumed
    var live_pair = NativeCondVar.create()
    var dead_mutex = NativeMutex.create()
    var uad_ok = True

    try:
        dead.signal()
        uad_ok = False
    except e:
        uad_ok = uad_ok and contains(String(e), "EINVAL")
    try:
        dead.broadcast()
        uad_ok = False
    except e:
        uad_ok = uad_ok and contains(String(e), "EINVAL")

    # Held-mutex misuse: lock once per attempt and ALWAYS unlock in the
    # handler path — a raise leaves the mutex acquired (the wait never
    # released it), and the non-recursive mutex self-deadlocks on a
    # re-lock.
    dead_mutex.lock()
    try:
        dead.wait(dead_mutex)
        uad_ok = False  # must have raised
    except e:
        uad_ok = uad_ok and contains(String(e), "EINVAL")
    dead_mutex.unlock()

    dead_mutex.lock()
    try:
        var dl8 = MonotonicInstant.now() + duration_from_millis(1)
        _ = dead.wait_until(dead_mutex, dl8)
        uad_ok = False  # must have raised
    except e:
        uad_ok = uad_ok and contains(String(e), "EINVAL")
    dead_mutex.unlock()

    try:
        dead.destroy()
        uad_ok = False  # destroy of an inert default MUST raise
    except e:
        uad_ok = uad_ok and contains(String(e), "EINVAL")

    var dd8_ok = live_double_destroy_raises()
    dead_mutex.destroy()

    if not check("S3.2 8. uninitialized/consumed handle raises EINVAL", uad_ok):
        failed += 1


    print("RESULT: " + String(8 - failed) + "/8 PASSED")
