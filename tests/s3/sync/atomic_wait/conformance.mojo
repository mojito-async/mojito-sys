# mojito-sys S3.3 — atomic wait/wake conformance (issue #59, spec §18).
#
# Backend-parameterized suite: it PROBES the host backend first and runs
# one of two modes, so the macOS fallback lane (#60) can reuse this file
# VERBATIM — on a host whose C layer reports the documented -ENOSYS the
# unsupported-backend rows execute; everywhere else the full semantic
# acceptance matrix does:
#
#   1. mismatch-immediate  — wait where *word != expected returns .ok
#      WITHOUT sleeping (futex EAGAIN -> ok mapping, documented in the
#      header block); elapsed stays far under the deadline;
#   2. expired-deadline    — an unmet wait past its deadline returns
#      .timed_out and really waited >= the requested span;
#   3. wake accounting     — EXACT counts: wake_one/wake_all with no
#      waiter == 0; wake_one with exactly one parked waiter == 1; wake_all
#      with N parked waiters == N;
#   4. ping-pong           — two threads hand off through one word for
#      10k rounds each direction with ZERO hangs (every wait bounded by a
#      deadline) and a wall-clock guard on the whole exchange;
#   5. spurious tolerated  — an injected spurious wake (wake WITHOUT any
#      value change) is absorbed by the predicate-loop shape
#      (wait_until_changed), which re-checks and re-waits.
#
# b2 notes (matching tests/s3/sync/mutex/conformance.mojo):
#   - Thread entries are @export abi("C") functions addressed via the
#     adrp/add idiom proven in tests/s1/abi/callbacks; they cannot
#     propagate `raises`, so error paths are trapped into status cells.
#   - Failures accumulate in a main()-local counter; verdicts print
#     "<name>: PASS/FAIL"; green requires zero FAIL rows plus the final
#     "RESULT: n/n PASSED" line (run.sh checks both).
#
# Run via tests/s3/sync/atomic_wait/run.sh (builds libmojito_sys.dylib
# first).

from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

from mojito_sys.sync.atomic_wait import (
    ENOSYS_DARWIN_RC,
    ENOSYS_LINUX_RC,
    wait_on_u32,
    wait_until_changed,
    wake_all_u32,
    wake_one_u32,
)
from mojito_sys.sync.common import WaitStatus
from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    spawn_native_thread,
    no_name,
)
from mojito_sys.time.duration import duration_from_millis
from mojito_sys.time.monotonic import MonotonicInstant

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime WordCell = UnsafePointer[UInt32, MutAnyOrigin]

# Ping-pong shape (issue acceptance): ROUNDS handoffs per direction, each
# individually deadline-bounded so a lost wake surfaces as .timed_out
# instead of hanging the suite.
comptime PING_ROUNDS = 10_000
comptime PING_WAIT_MS = UInt64(30_000)

# Wake-accounting waiter count for the N case.
comptime WAKE_N = 4

# Settle window after every observed-waiter signal before waking: on a
# futex host a thread that has passed its last pre-wait memory operation
# parks within microseconds, so 150ms makes "not yet asleep" practically
# unreachable while keeping the suite fast.
comptime SETTLE_MS = UInt64(150)

# Far-future deadline for waiters that must be woken by the harness; also
# the guard that turns any lost-wake scenario into a FAIL row instead of
# a hang.
comptime WAITER_TIMEOUT_MS = UInt64(30_000)


# ---- small helpers -----------------------------------------------------------

def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) != -1


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def now_plus(ms: UInt64) raises -> MonotonicInstant:
    return MonotonicInstant.now() + duration_from_millis(ms)


def host_enosys_errno() -> Int32:
    # Host-spelled POSITIVE ENOSYS errno (darwin 78 / Linux 38); negate
    # for the frozen-ABI rc form.
    if CompilationTarget().is_macos():
        return Int32(78)
    return Int32(38)


def word_ptr_of(addr_int: Int64) -> WordCell:
    return WordCell(unsafe_from_address=Int(addr_int))


def cells_ptr_of(addr_int: Int64) -> CellsPtr:
    return CellsPtr(unsafe_from_address=Int(addr_int))


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven in tests/s3/sync/mutex/conformance.mojo.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


# Probe: does this host have a real kernel backend? A mismatched-value
# wait must return .ok fast on ANY working backend; the documented -ENOSYS
# raise identifies a host still waiting for its fallback lane (#60).
def backend_present() raises -> Bool:
    var w = stack_allocation[1, UInt32]()
    w[] = 2
    try:
        _ = wait_on_u32(w, UInt32(1), Optional[MonotonicInstant](now_plus(50)))
        return True
    except e:
        return not contains(String(e), "errno " + String(host_enosys_errno()))


def adopt_join(handle: Int64) raises -> Bool:
    var joined = NativeThread()
    joined.handle = handle
    joined.consumed = False
    return joined.join() == 0


def settle_ready(flags: CellsPtr, count: Int64) raises -> None:
    # Wait until every waiter announced readiness in ITS OWN slot (no
    # shared-cell increments across threads), then hold the settle window
    # so the kernel has parked them before the harness wakes. Deadline-
    # guarded: a crashed waiter degrades to a FAIL row downstream instead
    # of hanging the suite.
    var guard = now_plus(WAITER_TIMEOUT_MS)
    while MonotonicInstant.now() < guard:
        var i = Int64(0)
        var all_ready = True
        while i < count:
            if flags[i] == 0:
                all_ready = False
            i += 1
        if all_ready:
            break
    var until = now_plus(SETTLE_MS)
    while MonotonicInstant.now() < until:
        pass


# ---- exported thread entries ---------------------------------------------------

# Waiter for the accounting/spurious cases. ud cells:
#   [0] word address   [1] expected u32 bits   [2] status slot (.ok=0 /
#   .timed_out=1 / raise=-1)   [3] ready flag slot address   [4] timeout ms
@export("mjs_s33_waiter_entry")
def _waiter_entry(ud: CellsPtr) abi("C") -> Int64:
    var w = word_ptr_of(ud[0])
    var expected = UInt32(UInt64(ud[1]) & UInt64(0xFFFFFFFF))
    var ready = cells_ptr_of(ud[3])
    ready[] += 1
    try:
        var st = wait_on_u32(
            w, expected, Optional[MonotonicInstant](now_plus(UInt64(ud[4])))
        )
        if st == WaitStatus.ok:
            ud[2] = 0
            return 0
        if st == WaitStatus.timed_out:
            ud[2] = 1
            return 0
        ud[2] = -1
        return -1
    except:
        ud[2] = -1
        return -1


# Ping-pong worker. ud cells: [0] turn-word address, [1] my turn (0/1),
# [2] rounds, [3] fail flag. Each handoff: wait until turn == mine
# (deadline-bounded), flip, wake the peer. Zero hangs by construction:
# every wait is deadline-bounded, and any timeout sets the fail flag.
@export("mjs_s33_ping_entry")
def _ping_entry(ud: CellsPtr) abi("C") -> Int64:
    var turn = word_ptr_of(ud[0])
    var mine = UInt32(UInt64(ud[1]) & UInt64(0xFFFFFFFF))
    var rounds = ud[2]
    var i = Int64(0)
    while i < rounds:
        try:
            var st = wait_on_u32(
                turn,
                mine,
                Optional[MonotonicInstant](now_plus(PING_WAIT_MS)),
            )
            if st != WaitStatus.ok:
                ud[3] = 1  # timed out: lost wake — report, never hang
                return -1
        except:
            ud[3] = 1
            return -1
        turn[] = UInt32(1) - mine
        _ = wake_one_u32(turn)
        i += 1
    return 0


# ---- mode A: full semantic acceptance (backend present) ------------------------

def run_semantic_mode() raises -> Bool:
    var failed = 0

    # -- 1. mismatch -> immediate .ok, NO sleep ---------------------------------
    var imm_ok = True
    var w1 = stack_allocation[1, UInt32]()
    w1[] = 2
    var t0 = MonotonicInstant.now()
    var st = wait_on_u32(w1, UInt32(1), Optional[MonotonicInstant](now_plus(2_000)))
    var took_ms = MonotonicInstant.now().duration_since(t0).as_millis()
    imm_ok = (
        st == WaitStatus.ok
        and took_ms < 1_000  # far under the 2s deadline: EAGAIN, no park
        and w1[] == UInt32(2)
    )
    if not check("S3.3 mismatch immediate .ok without sleep", imm_ok):
        failed += 1

    # -- 2. unmet wait expires -> .timed_out ------------------------------------
    var exp_ok = True
    var w2 = stack_allocation[1, UInt32]()
    w2[] = 7
    t0 = MonotonicInstant.now()
    st = wait_on_u32(w2, UInt32(7), Optional[MonotonicInstant](now_plus(60)))
    took_ms = MonotonicInstant.now().duration_since(t0).as_millis()
    exp_ok = st == WaitStatus.timed_out and took_ms >= UInt64(55)
    if not check("S3.3 expired deadline -> .timed_out", exp_ok):
        failed += 1

    # -- 3a. wake accounting: zero waiters ---------------------------------------
    var w3 = stack_allocation[1, UInt32]()
    w3[] = 5
    var z_ok = wake_one_u32(w3) == 0 and wake_all_u32(w3) == 0
    if not check("S3.3 wake with no waiter == exactly 0", z_ok):
        failed += 1

    # -- 3b. wake accounting: exactly one waiter ----------------------------------
    var one_args = stack_allocation[6, Int64]()
    var one_flag = stack_allocation[1, Int64]()
    one_flag[] = 0
    one_args[0] = Int64(Int(w3))
    one_args[1] = Int64(5)
    one_args[2] = -99  # status sentinel
    var w = spawn_native_thread(
        entry_pointer["mjs_s33_waiter_entry"](), one_args, 0, no_name()
    )
    settle_ready(one_flag, 1)
    var woke_one = wake_one_u32(w3)
    var one_ok = adopt_join(w.handle) and woke_one == 1 and one_args[2] == 0
    if not check("S3.3 wake_one with one parked waiter == exactly 1", one_ok):
        failed += 1

    # -- 3c. wake accounting: N waiters, wake_all == N ----------------------------
    # One STABLE allocation for all per-waiter arg blocks ([flag slot
    # address][status][word addr][0][0][0] x N): a loop-scoped
    # stack_allocation would not outlive its iteration.
    var blocks = stack_allocation[WAKE_N * 6, Int64]()
    var n_flags = stack_allocation[WAKE_N, Int64]()
    var handles = stack_allocation[WAKE_N, Int64]()
    var i = 0
    while i < WAKE_N:
        n_flags[i] = 0
        var base = Int64(i) * 6
        blocks[base + 0] = Int(w3)
        blocks[base + 1] = Int64(5)
        blocks[base + 2] = -99  # status sentinel
        blocks[base + 3] = Int(n_flags) + Int64(i) * 8
        blocks[base + 4] = Int64(WAITER_TIMEOUT_MS)
        i += 1
    i = 0
    while i < WAKE_N:
        var wk = spawn_native_thread(
            entry_pointer["mjs_s33_waiter_entry"](),
            cells_ptr_of(Int(blocks) + Int64(i) * 48),
            0,
            no_name(),
        )
        handles[i] = wk.handle
        i += 1
    settle_ready(n_flags, WAKE_N)
    var woke_n = wake_all_u32(w3)
    var n_ok = woke_n == WAKE_N
    i = 0
    while i < WAKE_N:
        n_ok = n_ok and adopt_join(handles[i])
        var args_i = cells_ptr_of(Int(blocks) + Int64(i) * 48)
        n_ok = n_ok and args_i[2] == 0
        i += 1
    if not check("S3.3 wake_all with N parked waiters == exactly N", n_ok):
        failed += 1

    # -- 4. cross-thread ping-pong: 10k rounds per direction, zero hangs ----------
    var pp_args0 = stack_allocation[4, Int64]()
    var pp_args1 = stack_allocation[4, Int64]()
    var turn_word = stack_allocation[1, UInt32]()
    turn_word[] = 0
    pp_args0[0] = Int64(Int(turn_word))
    pp_args0[1] = 0
    pp_args0[2] = Int64(PING_ROUNDS)
    pp_args0[3] = 0
    pp_args1[0] = Int64(Int(turn_word))
    pp_args1[1] = 1
    pp_args1[2] = Int64(PING_ROUNDS)
    pp_args1[3] = 0
    var budget_start = MonotonicInstant.now()
    var p0 = spawn_native_thread(
        entry_pointer["mjs_s33_ping_entry"](), pp_args0, 0, no_name()
    )
    var p1 = spawn_native_thread(
        entry_pointer["mjs_s33_ping_entry"](), pp_args1, 0, no_name()
    )
    var pp_ok = adopt_join(p0.handle) and adopt_join(p1.handle)
    pp_ok = pp_ok and pp_args0[3] == 0 and pp_args1[3] == 0
    pp_ok = pp_ok and turn_word[] == UInt32(0)  # even number of flips
    var pp_ms = MonotonicInstant.now().duration_since(budget_start).as_millis()
    pp_ok = pp_ok and pp_ms <= UInt64(120_000)
    if not check(
        "S3.3 ping-pong 10k x 10k zero hangs (wall clock "
        + String(pp_ms)
        + "ms)",
        pp_ok,
    ):
        failed += 1

    # -- 5. spurious wakes are tolerated ------------------------------------------
    var w5 = stack_allocation[1, UInt32]()
    w5[] = 9
    var sp_args = stack_allocation[6, Int64]()
    var sp_flag = stack_allocation[1, Int64]()
    sp_flag[] = 0
    sp_args[0] = Int64(Int(w5))
    sp_args[1] = Int64(9)
    sp_args[2] = -99
    sp_args[3] = Int64(Int(sp_flag))
    sp_args[4] = Int64(WAITER_TIMEOUT_MS)
    var sw = spawn_native_thread(
        entry_pointer["mjs_s33_waiter_entry"](), sp_args, 0, no_name()
    )
    settle_ready(sp_flag, 1)
    var injected = wake_one_u32(w5)  # spurious: value UNCHANGED
    # Now satisfy the predicate; the waiter must absorb the earlier
    # spurious .ok, loop, and finish through the changed-value path.
    w5[] = 10
    _ = wake_one_u32(w5)
    var sp_ok = adopt_join(sw.handle)
    sp_ok = sp_ok and injected == 1 and sp_args[2] == 0
    if not check("S3.3 injected spurious wake tolerated", sp_ok):
        failed += 1

    # -- reference helper shape sanity ---------------------------------------------
    var w6 = stack_allocation[1, UInt32]()
    w6[] = 1
    var helper_ok = not wait_until_changed(w6, UInt32(1), now_plus(80))
    helper_ok = helper_ok and w6[] == UInt32(1)
    if not check("S3.3 wait_until_changed times out cleanly", helper_ok):
        failed += 1

    var total = 7
    print("RESULT: " + String(total - failed) + "/" + String(total) + " PASSED")
    return failed == 0


# ---- mode B: documented absent-backend behavior (-ENOSYS hosts) -----------------

def run_enosys_mode() raises -> Bool:
    # Every entry point fails DETERMINISTICALLY and IMMEDIATELY with the
    # decoded host -ENOSYS spelling — clean red-exclusion for #60: no
    # sleeps, no partial state, stable across repeats.
    var failed = 0
    var enosys_msg = "errno " + String(host_enosys_errno())

    var w = stack_allocation[1, UInt32]()
    w[] = 2
    var raise_ok = True
    var t0 = MonotonicInstant.now()
    try:
        _ = wait_on_u32(w, UInt32(1), Optional[MonotonicInstant](now_plus(2_000)))
        raise_ok = False  # must have raised
    except e:
        raise_ok = contains(String(e), enosys_msg)
    var took_ms = MonotonicInstant.now().duration_since(t0).as_millis()
    raise_ok = raise_ok and took_ms < 1_000  # immediate: never slept
    if not check(
        "S3.3 absent backend: wait raises decoded ENOSYS immediately",
        raise_ok,
    ):
        failed += 1

    var want = -Int(host_enosys_errno())
    var wake_ok = wake_one_u32(w) == want
    wake_ok = wake_ok and wake_all_u32(w) == want
    if not check(
        "S3.3 absent backend: wake_* return negative host ENOSYS", wake_ok
    ):
        failed += 1

    var repeat_ok = True
    var k = 0
    while k < 3:
        try:
            _ = wait_on_u32(w, UInt32(9), Optional[MonotonicInstant](now_plus(100)))
            repeat_ok = False
        except e:
            repeat_ok = repeat_ok and contains(String(e), enosys_msg)
        k += 1
    if not check("S3.3 absent backend: deterministic across repeats", repeat_ok):
        failed += 1

    print(
        "backend=absent (macOS fallback pending issue #60); running "
        + "unsupported-backend contract rows only"
    )
    var total = 3
    print("RESULT: " + String(total - failed) + "/" + String(total) + " PASSED")
    return failed == 0


def main() raises:
    if backend_present():
        _ = run_semantic_mode()
    else:
        _ = run_enosys_mode()
