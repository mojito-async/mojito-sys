# mojito-sys S3.6 — cross-primitive integration (issue #62).
#
# Drives ALL FOUR S3 primitives against each other over real OS
# threads, phase-closing shape:
#
#   1. BOUNDED BUFFER (S3.1 NativeMutex + S3.2 NativeCondVar): 8
#     producers x 8 consumers move 100k items EACH (800k total) through
#     a 64-slot ring guarded by one mutex and two condvars (not_full /
#     not_empty). ZERO loss / ZERO duplication is asserted by STRICT
#     sequence reconciliation: every popped value v is marked in a
#     800k-bit seen[] table INSIDE the same critical section that pops
#     it — a re-mark is a duplication, a clear bit after joins is a
#     loss, and popcount(seen) MUST equal 800k exactly.
#   2. PARK/UNPARK CHURN (S3.5 NativeEvent + S3.3 AtomicWait): a worker
#     thread parks via mjs_atomic_wait_on_u32 on a u32 token word and
#     the spawner unparks via store + the wait_on_u32 WRAPPER's
#     wake_one_u32, 50k cycles, EXACT cycle accounting. Flow control is
#     FULLY BLOCKING, never polled: the worker acknowledges each
#     consumed token on a second u32 ack word and the spawner waits for
#     the ack with wait_until_changed() — plain spin loops on shared
#     cells are FORBIDDEN here because b2 hoists their loads (observed
#     stale reads hanging a spawner forever). Completion is announced
#     through the event's sticky token.
#   3. CROSS-PRIMITIVE WRAPPER DECODE (main scope): condvar timed-wait
#     expiry decodes .timed_out promptly; AtomicWait wrapper deadline
#     expiry decodes .timed_out and wake-with-no-waiters returns 0;
#     NativeEvent pre-signal stick completes immediately.
#
# EVERY blocking operation in every thread entry is DEADLINE-BOUNDED
# (absolute monotonic deadlines recomputed per park; first expiry is an
# error, never a hang), and the whole file is CI-bounded (< 60 s wall
# on the reference host; run.sh prints the measured time).
#
# b2 notes (verbatim discipline from tests/s3/sync/{condvar,event}):
#   - Thread entries are @export abi("C") defs materialized through the
#     entry_pointer[symbol]() adrp/add idiom; they drive SCALAR PROBE
#     SHIMS ONLY and decode raw rcs into cells with CONSTANT indices.
#     Wrapper methods are exercised from MAIN() scope only (crash
#     workaround 2); the spawner side of the churn drives the
#     scalar-returning wake_one_u32 wrapper directly.
#   - Raising calls never appear directly inside an @export frame: the
#     bodies are factored into plain `fn ... raises` halves wrapped in
#     try/except (the looper pattern from the condvar/event lanes).
#   - Failures accumulate in a main()-local counter (no module-level
#     mutable globals).
#
# Run via tests/s3/sync/integration/run.sh (builds libmojito_sys.dylib
# first); green requires the exact "RESULT: 3/3 PASSED" line.

from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

import mojito_sys.sync.externs as _externs
from mojito_sys.sync.atomic_wait import (
    wake_one_u32,
    wait_on_u32,
    wait_until_changed,
)
from mojito_sys.sync.common import WaitStatus
from mojito_sys.sync.condvar import NativeCondVar
from mojito_sys.sync.event import NativeEvent
from mojito_sys.sync.mutex import NativeMutex

from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    no_name,
    spawn_native_thread,
)
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant, _now_ns

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime U32Ptr = UnsafePointer[UInt32, MutAnyOrigin]

# ---- bounded-buffer shape (spec acceptance: 8 x 8 x 100k) --------------------
comptime N_PROD = 8
comptime N_CONS = 8
comptime ITEMS = 100_000
comptime RING_CAP = 64
comptime TOTAL = N_PROD * ITEMS  # == N_CONS * ITEMS == 800k

# Cells per thread-entry userdata block (CONSTANT indices, see head).
comptime UD_M = 0        # mutex handle
comptime UD_CV_FULL = 1  # not_full condvar handle (producers wait on it)
comptime UD_CV_EMPTY = 2  # not_empty condvar handle (consumers wait on it)
comptime UD_ROLE = 3     # 0 = producer, 1 = consumer
comptime UD_PID = 4      # producer id
comptime UD_DONE = 5     # items moved
comptime UD_ERR = 6      # 0 ok / 1 expired deadline / 2 unexpected rc / 3 dup
comptime UD_RING = 7     # ring base address
comptime UD_HEAD = 8
comptime UD_TAIL = 9
comptime UD_COUNT = 10
comptime UD_SEEN = 11    # seen-bitmap base address (u32 words)

comptime UD_STRIDE = 12

# Per-park absolute deadline margin. Never taken on a green run; turns
# any lost wakeup into a loud error instead of a hung CI job.
comptime PARK_BUDGET_S = 30

# Churn shape (spec acceptance: 50k park/unpark cycles).
comptime CHURN_CYCLES = 50_000

comptime SEEN_WORDS = TOTAL // 32


# ---- shared helpers ----------------------------------------------------------

@extern("usleep")
def _libc_usleep(useconds: UInt32) abi("C") -> Int32:
    ...


# Host-spelled -ETIMEDOUT (darwin 60 / Linux 110), usable everywhere
# (scalar only).
def _et_rc() -> Int32:
    if CompilationTarget().is_macos():
        return Int32(-60)
    return Int32(-110)


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven across every s3 lane.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


# Re-adopt a raw thread handle for joining (fields public by design).
def adopt_join(handle: Int64) raises -> Int64:
    var w = NativeThread()
    w.handle = handle
    w.consumed = False
    return w.join()


# Sub-block view into an arena at cell offset `first_cell` (main scope).
def cell_block(arena: CellsPtr, first_cell: Int) -> CellsPtr:
    return UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(arena) + first_cell * 8
    )


# Absolute-deadline convenience for MAIN scope: now + seconds.
def deadline_after(seconds: UInt64) raises -> MonotonicInstant:
    return MonotonicInstant.now() + duration_from_millis(seconds * 1000)


# Wall-clock-guarded progress wait: poll until every worker block has
# finished ITEMS items (or raised UD_ERR) or `cap_ms` elapses. Returns
# False on the cap (test failure path, never taken green).
def await_threads(arena: CellsPtr, nthreads: Int, cap_ms: UInt64) raises -> Bool:
    var t0 = MonotonicInstant.now()
    while True:
        var all_done = True
        var t = 0
        while t < nthreads:
            var ud = cell_block(arena, t * UD_STRIDE)
            if ud[UD_ERR] != 0 or ud[UD_DONE] < ITEMS:
                all_done = False
            t += 1
        if all_done:
            return True
        if (
            MonotonicInstant.now().duration_since(t0).ns
            > cap_ms * UInt64(1_000_000)
        ):
            return False
        _ = _libc_usleep(2000)


# ---- 1. bounded-buffer workers ------------------------------------------------

# NOTE: the producer/consumer loop bodies live INLINE in this @export
# frame (try/except-wrapped). Factoring them into separate raising
# helpers segfaults b2 1.0.0b2 (export -> raising helper -> probe is a
# known poison shape); the condvar/event lanes keep the same code
# inline for exactly this reason.
@export("mjs_s36_buffer_entry")
def _buffer_entry(ud: CellsPtr) abi("C") -> Int64:
    # Blocking: YES (SYS-5) — producers park on not_full, consumers on
    #   not_empty; EVERY park carries a fresh absolute monotonic
    #   deadline whose expiry is a loud error, never a hang.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    var m = ud[UD_M]
    var cv_not_full = ud[UD_CV_FULL]
    var cv_not_empty = ud[UD_CV_EMPTY]
    var ring = UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(ud[UD_RING])
    )
    var head = UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(ud[UD_HEAD])
    )
    var tail = UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(ud[UD_TAIL])
    )
    var count = UnsafePointer[Int64, MutAnyOrigin](
        unsafe_from_address=Int(ud[UD_COUNT])
    )
    var seen = U32Ptr(unsafe_from_address=Int(ud[UD_SEEN]))
    var et = _et_rc()
    var budget_ns = UInt64(PARK_BUDGET_S) * UInt64(1_000_000_000)

    try:
        if ud[UD_ROLE] == 0:
            # Producer: push ITEMS uniquely-tagged values pid*ITEMS+i.
            var pid = ud[UD_PID]
            var i = 0
            while i < ITEMS:
                _ = _externs.probe_lock(m)
                while count[] == RING_CAP:
                    var rc = _externs.probe_cv_wait_until(
                        cv_not_full, m, _now_ns() + budget_ns
                    )
                    if rc == et:
                        _ = _externs.probe_unlock(m)
                        ud[UD_ERR] = 1
                        return -1
                    if rc != 0:
                        _ = _externs.probe_unlock(m)
                        ud[UD_ERR] = 2
                        return -1
                ring[tail[] % RING_CAP] = pid * ITEMS + Int64(i)
                tail[] += 1
                count[] += 1
                _ = _externs.probe_cv_signal(cv_not_empty)
                _ = _externs.probe_unlock(m)
                i += 1
            ud[UD_DONE] = ITEMS
        else:
            # Consumer: pop ITEMS values; mark seen[v] INSIDE the pop
            # critical section — a re-mark is a duplication (loud,
            # UD_ERR=3), any bit still clear after joins is a loss.
            var k = 0
            while k < ITEMS:
                _ = _externs.probe_lock(m)
                while count[] == 0:
                    var rc = _externs.probe_cv_wait_until(
                        cv_not_empty, m, _now_ns() + budget_ns
                    )
                    if rc == et:
                        _ = _externs.probe_unlock(m)
                        ud[UD_ERR] = 1
                        return -1
                    if rc != 0:
                        _ = _externs.probe_unlock(m)
                        ud[UD_ERR] = 2
                        return -1
                var v = ring[head[] % RING_CAP]
                head[] += 1
                count[] -= 1
                var word = v >> 5
                var bit = UInt32(1) << UInt32(v & 31)
                var cur = seen[word]
                if (cur & bit) != 0:
                    ud[UD_ERR] = 3  # duplicated value — hard failure
                else:
                    seen[word] = cur | bit
                _ = _externs.probe_cv_signal(cv_not_full)
                _ = _externs.probe_unlock(m)
                if ud[UD_ERR] != 0:
                    return -1
                k += 1
            ud[UD_DONE] = ITEMS
    except:
        return -1
    return 0


# ud layout: [0]=token word address [1]=cycles done [2]=err
#            [3]=done-event handle [4]=ack word address. The worker
#            parks on the u32 token word via mjs_atomic_wait_on_u32
#            (deadline-bounded EVERY park); after consuming a token it
#            ACKNOWLEDGES on the ack word (store 1 + wake_one) so the
#            spawner never issues a second token unaccounted for.
#
# Blocking: YES (SYS-5) — parks on the token word every cycle; each
#   park carries a fresh absolute monotonic deadline whose expiry is a
#   loud error, never a hang. Allocation: one stack deadline cell
#   (SYS-4). Task-aware: no.
@export("mjs_s36_churn_entry")
def _churn_entry(ud: CellsPtr) abi("C") -> Int64:
    var token = U32Ptr(unsafe_from_address=Int(ud[0]))
    var ack = U32Ptr(unsafe_from_address=Int(ud[4]))
    var et = _et_rc()
    var dl = stack_allocation[1, UInt64]()
    var cycles = 0
    try:
        while cycles < CHURN_CYCLES:
            if token[] != 0:
                token[] = 0  # consume the token
                cycles += 1
                ud[1] = Int64(cycles)
                ack[] = 1  # acknowledge: spawner may issue the next one
                _ = _externs.probe_wake_one(ack)
                continue
            dl[] = _now_ns() + UInt64(PARK_BUDGET_S) * UInt64(1_000_000_000)
            var rc = _externs.probe_wait_on(token, Int32(0), dl)
            if rc == et:
                ud[2] = 1  # lost wakeup: expired while a handoff was open
                return -1
            if rc != 0:
                ud[2] = 2  # genuine error
                return -1
            # .ok (or EAGAIN fold-in): re-check the predicate, loop.
        _ = _externs.probe_ev_signal(ud[3])  # sticky token: completion
    except:
        return -1
    return 0


# ---- 3. main-scope wrapper decode helpers --------------------------------------

# Condvar timed wait must expire promptly with .timed_out.
def cv_deadline_decode_ok() raises -> Bool:
    # Blocking: YES (SYS-5) — bounded by an 80 ms deadline.
    # Allocation: none (SYS-4). Task-aware: no.
    var m = NativeMutex.create()
    var c = NativeCondVar.create()
    var t0 = MonotonicInstant.now()
    m.lock()
    var st = c.wait_until(m, t0 + duration_from_millis(80))
    m.unlock()
    var ms = MonotonicInstant.now().duration_since(t0).ns // 1_000_000
    c.destroy()
    m.destroy()
    return st == WaitStatus.timed_out and ms < UInt64(5000)


# AtomicWait wrapper: untouched word expires .timed_out promptly;
# waking nobody reports the exact count 0.
def atomic_wrapper_decode_ok() raises -> Bool:
    # Blocking: YES (SYS-5) — bounded by an 80 ms deadline.
    # Allocation: none (SYS-4). Task-aware: no.
    var word = stack_allocation[1, UInt32]()
    word[] = 7
    var t0 = MonotonicInstant.now()
    var st = wait_on_u32(word, UInt32(7), deadline_after(0) - duration_from_millis(920))
    var ms = MonotonicInstant.now().duration_since(t0).ns // 1_000_000
    var woke_none = wake_one_u32(word) == 0
    return st == WaitStatus.timed_out and ms < UInt64(5000) and woke_none


def main() raises:
    var failed = 0
    var t_start = MonotonicInstant.now()

    # ---- 1. bounded buffer: 8 x 8 x 100k, zero loss / zero duplication -------
    var arena = stack_allocation[(N_PROD + N_CONS) * UD_STRIDE, Int64]()
    var ring = stack_allocation[RING_CAP, Int64]()
    var head_cell = stack_allocation[1, Int64]()
    var tail_cell = stack_allocation[1, Int64]()
    var count_cell = stack_allocation[1, Int64]()
    var seen = stack_allocation[SEEN_WORDS, UInt32]()
    var bm = NativeMutex.create()
    var cv_full = NativeCondVar.create()
    var cv_empty = NativeCondVar.create()

    # stack_allocation does NOT zero-initialize: every cell the workers
    # read before first write MUST be zeroed here (a garbage count makes
    # consumers pop unwritten slots and producers see a full ring).
    head_cell[] = 0
    tail_cell[] = 0
    count_cell[] = 0
    var zw = 0
    while zw < SEEN_WORDS:
        seen[zw] = 0
        zw += 1

    var i = 0
    while i < N_PROD + N_CONS:
        var ud = cell_block(arena, i * UD_STRIDE)
        ud[UD_M] = bm.handle
        ud[UD_CV_FULL] = cv_full.handle
        ud[UD_CV_EMPTY] = cv_empty.handle
        ud[UD_ERR] = 0
        ud[UD_DONE] = 0
        ud[UD_RING] = Int64(Int(ring))
        ud[UD_HEAD] = Int64(Int(head_cell))
        ud[UD_TAIL] = Int64(Int(tail_cell))
        ud[UD_COUNT] = Int64(Int(count_cell))
        ud[UD_SEEN] = Int64(Int(seen))
        if i < N_PROD:
            ud[UD_ROLE] = 0
            ud[UD_PID] = Int64(i)
        else:
            ud[UD_ROLE] = 1
        i += 1

    var handles = stack_allocation[N_PROD + N_CONS, Int64]()
    i = 0
    while i < N_PROD + N_CONS:
        var w = spawn_native_thread(
            entry_pointer["mjs_s36_buffer_entry"](),
            cell_block(arena, i * UD_STRIDE),
            0,
            no_name(),
        )
        handles[i] = w.handle
        i += 1

    var progressed = await_threads(arena, N_PROD + N_CONS, UInt64(45_000))

    var bb_joins_ok = True
    i = 0
    while i < N_PROD + N_CONS:
        bb_joins_ok = bb_joins_ok and adopt_join(handles[i]) == 0
        i += 1

    # Strict reconciliation: no error anywhere, and popcount(seen) ==
    # TOTAL exactly (dup marks were already fatal inside the workers).
    var errs = 0
    i = 0
    while i < N_PROD + N_CONS:
        errs += Int(cell_block(arena, i * UD_STRIDE)[UD_ERR])
        i += 1
    var ones = 0
    i = 0
    while i < SEEN_WORDS:
        var w = seen[i]
        while w != 0:
            w = w & (w - 1)
            ones += 1
        i += 1

    var bb_ok = progressed and bb_joins_ok
    bb_ok = bb_ok and errs == 0 and ones == TOTAL
    bm.destroy()
    cv_full.destroy()
    cv_empty.destroy()
    if not check("S3.6 1. bounded buffer 8x8x100k — zero loss / zero duplication", bb_ok):
        failed += 1

    # ---- 2. park/unpark churn: NativeEvent + AtomicWait, 50k exact cycles ----
    var churn_ud = stack_allocation[5, Int64]()
    var tok_word = stack_allocation[1, UInt32]()
    var ack_word = stack_allocation[1, UInt32]()
    tok_word[] = 0
    ack_word[] = 0
    churn_ud[0] = Int64(Int(tok_word))
    churn_ud[1] = 0
    churn_ud[2] = 0
    var done_ev = NativeEvent.create()
    churn_ud[3] = done_ev.handle
    churn_ud[4] = Int64(Int(ack_word))

    var worker = spawn_native_thread(
        entry_pointer["mjs_s36_churn_entry"](), churn_ud, 0, no_name(),
    )

    # Spawner side: one token per cycle, then BLOCK on the worker's ack
    # word (wait_until_changed parks via the same atomic-wait backend —
    # zero spinning, exact accounting by construction).
    var t_churn = MonotonicInstant.now()
    var churn_flow_ok = True
    var cyc = 0
    while cyc < CHURN_CYCLES:
        tok_word[] = 1
        _ = wake_one_u32(tok_word)
        var acked = wait_until_changed(ack_word, UInt32(0), deadline_after(30))
        if not acked:
            churn_flow_ok = False
            break
        ack_word[] = 0
        cyc += 1

    # Completion announced via the event's sticky token, bounded.
    var done_st = done_ev.wait_until(deadline_after(45))
    var churn_ms = MonotonicInstant.now().duration_since(t_churn).ns // 1_000_000
    var jrc = adopt_join(worker.handle)
    done_ev.destroy()

    var churn_ok = churn_flow_ok
    churn_ok = churn_ok and done_st == WaitStatus.ok
    churn_ok = churn_ok and churn_ud[2] == 0
    churn_ok = churn_ok and churn_ud[1] == Int64(CHURN_CYCLES)
    churn_ok = churn_ok and jrc == 0
    churn_ok = churn_ok and churn_ms < UInt64(45_000)
    if not check("S3.6 2. park/unpark churn 50k cycles (NativeEvent + AtomicWait)", churn_ok):
        failed += 1

    # ---- 3. cross-primitive wrapper decode ------------------------------------
    var cv_ok = cv_deadline_decode_ok()
    var aw_ok = atomic_wrapper_decode_ok()
    var ev = NativeEvent.create()
    ev.signal()  # nobody waiting: token sticks
    var t3 = MonotonicInstant.now()
    var ps = ev.wait_until(t3 + duration_from_millis(5000))
    var ps_ms = MonotonicInstant.now().duration_since(t3).ns // 1_000_000
    ev.destroy()
    var wrap_ok = cv_ok and aw_ok
    wrap_ok = wrap_ok and ps == WaitStatus.ok and ps_ms < UInt64(100)
    if not check("S3.6 3. cross-primitive wrapper decode (mutex+cv / atomic-wait / event)", wrap_ok):
        failed += 1

    var total_ms = MonotonicInstant.now().duration_since(t_start).ns // 1_000_000
    print("wall: " + String(total_ms // 1000) + "." + String(total_ms % 1000) + "s")
    print("RESULT: " + String(3 - failed) + "/3 PASSED")
    if failed != 0:
        # raise-free failure exit for the AOT runner contract
        return
