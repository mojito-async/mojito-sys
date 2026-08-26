# mojito-sys S2.8 — lifecycle stress: spawn/join storms + TLS churn
# (SYS-D6, issue #55; spec §41 "lifecycle stress tests" L2330, borrowing the
# §38.5 jcstress actor/outcome methodology L1873-1875 and the S1.9 #31
# harness conventions).
#
# Three deterministic phases over the merged S2 surface (mjs_thread_* via
# mojito_sys.thread.externs probes; mjs_tls_* via NativeTlsKey):
#
#   A. SPAWN/JOIN STORM — 8 concurrent writer threads x N rounds each spawn a
#      leaf child and join it. Every child performs TLS slot churn under one
#      shared counting-destructor key: bind its OWN payload cell, read it
#      back (round-trip), then either leave it bound (even rounds) or clear
#      it first (odd rounds). POSIX semantics: the destructor fires EXACTLY
#      ONCE per binding still bound at child exit and never for cleared
#      values, so destructor accounting is exact arithmetic, not a heuristic.
#
#   B. 32-WAY BARRIER SPAWN BURSTS — B bursts of 32 simultaneous threads.
#      Each participant arrives at a seq-cst sense barrier (shim atomics),
#      records the generation it observed AFTER release into its own ledger
#      slot (lost-wake detection: every participant MUST observe generation
#      b+1), then performs one leave-bound TLS churn op. Main joins every
#      handle EXACTLY ONCE and asserts the second join hits the frozen T**
#      consumed-handle contract (-EINVAL) — zero silent double-joins.
#
#   C. EXACT RECONCILIATION — every actor outcome lands in a SHARD of the
#      outcome ledger (8 atomic Int64 cells per writer, cache-strided by
#      writer index, updated ONLY through mjs_fx_fetch_add). Main sums the
#      shards after joins (join = synchronization point) and requires EVERY
#      total to match its closed-form expectation exactly: spawned ==
#      joined == WRITERS*rounds, status sum 0, round-trips == spawns,
#      dtor expected == dtor observed == bound-round count, joined burst
#      threads == bursts*32 with zero lost wakes, zero double-join misses.
#      Any drift is a lost update / double-consume / missed wake and FAILS.
#
# Determinism: counts are fixed, no sleeps gate any assertion (the only
# yield points are pthread create/join and the barrier itself); the suite is
# pass/fail exact at both scales:
#   default (CI, Tier-0 budget <2min): N=25 rounds/writer, 4 bursts;
#   MOJITO_STRESS_SOAK=1 (local):      N=250 rounds/writer, 12 bursts.
#
# b2 notes (repo conventions, see tests/s2/thread/thread_test.mojo):
#   - Entry mechanism: @export abi("C") defs addressed via the entry_pointer
#     adrp/add idiom (tests/s1/abi/callbacks/conformance_test.mojo).
#   - Actor entries are NON-RAISING: raw probe_/mjs_ calls + raw Int64-cell
#     memory only; all verdicts travel through the ledger, never exceptions,
#     because an abi("C") frame cannot carry a raise across the boundary.
#   - No module-level mutable globals (first-consumer contract): the key id,
#     entry words, shard pointers all travel through caller-carved cells.
#   - Null pointers come from a RUNTIME zero (`unsafe_from_address=0`
#     literals are rejected in 1.0.0b2).
#   - Frames that reach mjs_thread_spawn keep the WORKAROUND shape (#49):
#     flat scalars/pointers only, finished pointers carved outside the
#     extern-reaching frame, no aggregates by value anywhere near it.
#   - Dispatchers stay <=7 branches (b2 miscompiles bigger if/elif chains).
#
# Run via tests/s2/stress/run.sh (builds libmojito_sys + atomic_shim.o,
# links them into this driver AOT). Green requires the exact line
#   RESULT: s2-stress green

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from fx_externs import c_exit, c_getenv, c_sched_yield, fx_add, fx_load, fx_store
from mojito_sys.thread.externs import (
    CThreadEntry,
    NamePtr,
    UserdataPtr,
    probe_join,
    probe_spawn,
)
from mojito_sys.thread.tls import (
    TlsDtorPtr,
    TlsValuePtr,
    create_tls_key,
    mjs_tls_get,
    mjs_tls_set,
)

# ---- scale ------------------------------------------------------------------

comptime WRITERS = 8
comptime ROUNDS_CI = 25       # children per writer, CI/Tier-0 scale
comptime ROUNDS_SOAK = 250    # children per writer, local soak scale
comptime BURSTS_CI = 4        # barrier bursts, CI/Tier-0 scale
comptime BURSTS_SOAK = 12     # barrier bursts, local soak scale
comptime BURST_N = 32         # spec-fixed burst width

# ---- outcome-ledger shard layout (SHARD cells per writer) -------------------

comptime SHARD = 8
comptime L_SPAWNED = 0
comptime L_JOINED = 1
comptime L_STATUS_SUM = 2
comptime L_DTOR_EXPECTED = 3
comptime L_DTOR_OBSERVED = 4
comptime L_ROUNDTRIP_OK = 5
comptime L_SPAWN_FAIL = 6
comptime L_JOIN_FAIL = 7

# ---- writer context cells (per writer) --------------------------------------

comptime WC_KEY = 0
comptime WC_ROUNDS = 1
comptime WC_SHARD = 2
comptime WC_ENTRY = 3
comptime WC_CELLS = 4

# ---- work-order cells (carved per round by the writer, read by the child) ---

comptime WO_KEY = 0
comptime WO_PAYLOAD = 1
comptime WO_LEAVE_BOUND = 2
comptime WO_GOT_OK = 3
comptime WO_SET_RC = 4
comptime WO_CELLS = 5

# ---- burst argument cells (per participant) ---------------------------------

comptime BA_BARRIER = 0
comptime BA_SLOT = 1
comptime BA_KEY = 2
comptime BA_PAYLOAD = 3
comptime BA_CELLS = 4

# ---- shared barrier state cells ---------------------------------------------

comptime BS_COUNT = 0
comptime BS_GEN = 1
comptime BS_CELLS = 2

# Frozen ABI consumed-handle misuse code (deterministic -EINVAL).
comptime RC_EINVAL = Int32(-22)

comptime WordPtr = UnsafePointer[Int64, MutAnyOrigin]


# ---- small helpers ----------------------------------------------------------

def word_ptr(a: Int) -> WordPtr:
    return WordPtr(unsafe_from_address=a)


def null_name() -> NamePtr:
    var z = 0
    return NamePtr(unsafe_from_address=z)


def null_value() -> TlsValuePtr:
    var z = 0
    return TlsValuePtr(unsafe_from_address=z)


def ptr_at(a: Int) -> TlsValuePtr:
    return TlsValuePtr(unsafe_from_address=a)


# Code address of an @export'd abi("C") def as a C function pointer — the
# adrp/add idiom proven in tests/s1/abi/callbacks/conformance_test.mojo.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


def soak_enabled() -> Bool:
    var name = stack_allocation[24, Byte]()
    var lit = String("MOJITO_STRESS_SOAK")
    var src = lit.unsafe_ptr()
    var i = 0
    while i < lit.byte_length():
        name[i] = src[i]
        i += 1
    name[lit.byte_length()] = 0
    var v = c_getenv(name)
    if Int(v) == 0:
        return False
    return v[0] == Byte(49)  # '1'


# ---- exported actors --------------------------------------------------------

# Counting TLS destructor (ms_callback shape): increments the Int64 cell the
# dying binding points at. Accounting lives IN THE PAYLOAD, never in a
# global — exactly the tls_test.mojo payload protocol.
@export("s28_counting_dtor")
def counting_dtor(value: TlsValuePtr) abi("C"):
    var cell = value.bitcast[Int64]()
    cell[] = cell[] + 1


# Leaf child of phase A: one TLS churn cycle. Non-raising; every observable
# outcome is written back into the work order for the writer's ledger.
@export("s28_leaf_entry")
def leaf_entry(ud: UserdataPtr) abi("C") -> Int64:
    var key_id = UInt(ud[WO_KEY])
    var payload_addr = Int(ud[WO_PAYLOAD])
    var set_rc = mjs_tls_set(key_id, ptr_at(payload_addr))
    ud[WO_SET_RC] = Int64(set_rc)
    var got = mjs_tls_get(key_id)
    ud[WO_GOT_OK] = 1 if Int(got) == payload_addr else 0
    if ud[WO_LEAVE_BOUND] == 0:
        var clr_rc = mjs_tls_set(key_id, null_value())
        if clr_rc != 0:
            ud[WO_SET_RC] = Int64(clr_rc)
            ud[WO_GOT_OK] = 0
    return 0


# Phase-A writer storm actor: N sequential spawn/join rounds of leaf
# children, outcomes accumulated atomically into THIS writer's shard only.
@export("s28_writer_entry")
def writer_entry(ud: UserdataPtr) abi("C") -> Int64:
    var key_id = UInt(ud[WC_KEY])
    var rounds = ud[WC_ROUNDS]
    var shard = word_ptr(Int(ud[WC_SHARD]))
    var leaf = CThreadEntry(unsafe_from_address=Int(ud[WC_ENTRY]))
    var r = 0
    while r < Int(rounds):
        var payload = stack_allocation[1, Int64]()
        payload[0] = 0
        var wo = stack_allocation[WO_CELLS, Int64]()
        wo[WO_KEY] = Int64(key_id)
        wo[WO_PAYLOAD] = Int64(Int(payload))
        wo[WO_LEAVE_BOUND] = Int64(r & 1)  # odd rounds stay bound
        wo[WO_GOT_OK] = 0
        wo[WO_SET_RC] = -1
        var hslot = stack_allocation[1, Int64]()
        hslot[0] = 0
        var src = probe_spawn(leaf, wo, 0, null_name(), hslot)
        if src != 0:
            _ = fx_add(shard + L_SPAWN_FAIL, 1)
        else:
            _ = fx_add(shard + L_SPAWNED, 1)
            var status = stack_allocation[1, Int64]()
            status[0] = -1
            var jrc = probe_join(hslot, status)
            if jrc != 0:
                _ = fx_add(shard + L_JOIN_FAIL, 1)
            else:
                _ = fx_add(shard + L_JOINED, 1)
                _ = fx_add(shard + L_STATUS_SUM, status[0])
                # join is the sync point: the child's work order and its
                # destructor firing are visible from here on.
                if wo[WO_LEAVE_BOUND] != 0:
                    _ = fx_add(shard + L_DTOR_EXPECTED, 1)
                _ = fx_add(shard + L_DTOR_OBSERVED, payload[0])
                if wo[WO_GOT_OK] != 0 and wo[WO_SET_RC] == 0:
                    _ = fx_add(shard + L_ROUNDTRIP_OK, 1)
        r += 1
    return 0


# Phase-B burst participant: arrive at the seq-cst sense barrier, record the
# post-release generation into the participant's ledger slot (lost-wake
# proof), then one leave-bound TLS churn op.
@export("s28_burst_entry")
def burst_entry(ud: UserdataPtr) abi("C") -> Int64:
    var bs = word_ptr(Int(ud[BA_BARRIER]))
    var slot = word_ptr(Int(ud[BA_SLOT]))
    var key_id = UInt(ud[BA_KEY])
    var payload_addr = Int(ud[BA_PAYLOAD])
    var gen = fx_load(bs + BS_GEN)
    var arrived = fx_add(bs + BS_COUNT, 1)
    if arrived == BURST_N - 1:
        fx_store(bs + BS_COUNT, 0)
        _ = fx_add(bs + BS_GEN, 1)
    else:
        while fx_load(bs + BS_GEN) == gen:
            _ = c_sched_yield()
    slot[0] = fx_load(bs + BS_GEN)
    var set_rc = mjs_tls_set(key_id, ptr_at(payload_addr))
    var got = mjs_tls_get(key_id)
    var ok = 0
    if set_rc == 0 and Int(got) == payload_addr:
        ok = 1
    slot[1] = Int64(ok)
    return 0


# ---- driver -----------------------------------------------------------------

def main() raises:
    var failed = 0
    var soak = soak_enabled()
    var rounds = ROUNDS_CI
    var bursts = BURSTS_CI
    if soak:
        rounds = ROUNDS_SOAK
        bursts = BURSTS_SOAK
    print(
        "S2-STRESS scale: writers=", WRITERS, " rounds/writer=", rounds,
        " bursts=", bursts, "x", BURST_N, " threads (soak=", soak, ")",
    )

    # One shared counting-destructor key across BOTH phases; ids are never
    # reused, so a stale handle can never alias a newer key mid-storm.
    var key = create_tls_key(
        entry_pointer["s28_counting_dtor"]().bitcast[NoneType]()
    )

    # ================= phase A: 8-writer spawn/join storm ===================
    var shards = stack_allocation[WRITERS * SHARD, Int64]()
    var ctx = stack_allocation[WRITERS * WC_CELLS, Int64]()
    var wslots = stack_allocation[WRITERS, Int64]()
    var wstat = stack_allocation[WRITERS, Int64]()
    var i = 0
    while i < WRITERS * SHARD:
        shards[i] = 0
        i += 1
    var leaf_word = Int(entry_pointer["s28_leaf_entry"]())
    var writer_word = Int(entry_pointer["s28_writer_entry"]())
    i = 0
    while i < WRITERS:
        ctx[i * WC_CELLS + WC_KEY] = Int64(Int(key.key))
        ctx[i * WC_CELLS + WC_ROUNDS] = Int64(rounds)
        ctx[i * WC_CELLS + WC_SHARD] = Int64(Int(shards + i * SHARD))
        ctx[i * WC_CELLS + WC_ENTRY] = Int64(leaf_word)
        wslots[i] = 0
        i += 1

    # Spawn ALL writers before joining ANY so the storms actually overlap.
    var spawn_fail = 0
    i = 0
    while i < WRITERS:
        var rc = probe_spawn(
            CThreadEntry(unsafe_from_address=writer_word),
            ctx + i * WC_CELLS,
            0,
            null_name(),
            wslots + i,
        )
        if rc != 0:
            spawn_fail += 1
        i += 1
    i = 0
    while i < WRITERS:
        wstat[i] = -1
        if probe_join(wslots + i, wstat + i) != 0:
            failed += 1
            print("S2-STRESS FAIL: writer ", i, " join rc != 0")
        elif wstat[i] != 0:
            failed += 1
            print("S2-STRESS FAIL: writer ", i, " exit status ", wstat[i])
        i += 1
    if spawn_fail != 0:
        failed += 1
        print("S2-STRESS FAIL: writer spawn failures: ", spawn_fail)

    # Exact reconciliation of the sharded storm ledger.
    var exp_rounds = Int64(WRITERS * rounds)
    var exp_bound = Int64((rounds // 2) * WRITERS)
    var agg = stack_allocation[SHARD, Int64]()
    var s = 0
    while s < SHARD:
        agg[s] = 0
        s += 1
    i = 0
    while i < WRITERS:
        s = 0
        while s < SHARD:
            agg[s] += shards[i * SHARD + s]
            s += 1
        i += 1
    print(
        "S2-STRESS storm ledger: spawned=", agg[L_SPAWNED],
        " joined=", agg[L_JOINED], " status_sum=", agg[L_STATUS_SUM],
        " roundtrip_ok=", agg[L_ROUNDTRIP_OK],
        " dtor_expected=", agg[L_DTOR_EXPECTED],
        " dtor_observed=", agg[L_DTOR_OBSERVED],
        " spawn_fail=", agg[L_SPAWN_FAIL],
        " join_fail=", agg[L_JOIN_FAIL],
    )
    if agg[L_SPAWNED] != exp_rounds:
        failed += 1
        print("S2-STRESS FAIL: spawned ", agg[L_SPAWNED], " != ", exp_rounds)
    if agg[L_JOINED] != exp_rounds:
        failed += 1
        print("S2-STRESS FAIL: joined ", agg[L_JOINED], " != ", exp_rounds)
    if agg[L_STATUS_SUM] != 0:
        failed += 1
        print("S2-STRESS FAIL: nonzero child statuses, sum=", agg[L_STATUS_SUM])
    if agg[L_ROUNDTRIP_OK] != exp_rounds:
        failed += 1
        print(
            "S2-STRESS FAIL: TLS round-trips ", agg[L_ROUNDTRIP_OK],
            " != ", exp_rounds,
        )
    if agg[L_DTOR_EXPECTED] != exp_bound or agg[L_DTOR_OBSERVED] != exp_bound:
        failed += 1
        print(
            "S2-STRESS FAIL: dtor accounting expected=", exp_bound,
            " got expected/observed=",
            agg[L_DTOR_EXPECTED], "/", agg[L_DTOR_OBSERVED],
        )
    if agg[L_SPAWN_FAIL] != 0 or agg[L_JOIN_FAIL] != 0:
        failed += 1
        print(
            "S2-STRESS FAIL: child spawn/join failures ",
            agg[L_SPAWN_FAIL], "/", agg[L_JOIN_FAIL],
        )

    # ================= phase B: 32-way barrier spawn bursts ==================
    var bs = stack_allocation[BS_CELLS, Int64]()
    bs[BS_COUNT] = 0
    bs[BS_GEN] = 0
    var joined_total = 0
    var lost_wakes = 0
    var double_join_ok = 0
    var churn_bad = 0
    var dtor_misses = 0
    var burst_spawn_fail = 0
    var burst_ep = entry_pointer["s28_burst_entry"]()
    var b = 0
    while b < bursts:
        var payloads = stack_allocation[BURST_N, Int64]()
        var slots = stack_allocation[BURST_N * 2, Int64]()
        var barg = stack_allocation[BURST_N * BA_CELLS, Int64]()
        var bh = stack_allocation[BURST_N, Int64]()
        var bstat = stack_allocation[BURST_N, Int64]()
        i = 0
        while i < BURST_N:
            payloads[i] = 0
            slots[i * 2] = 0
            slots[i * 2 + 1] = 0
            barg[i * BA_CELLS + BA_BARRIER] = Int64(Int(bs))
            barg[i * BA_CELLS + BA_SLOT] = Int64(Int(slots + i * 2))
            barg[i * BA_CELLS + BA_KEY] = Int64(Int(key.key))
            barg[i * BA_CELLS + BA_PAYLOAD] = Int64(Int(payloads + i))
            bh[i] = 0
            i += 1
        i = 0
        while i < BURST_N:
            var rc = probe_spawn(
                burst_ep, barg + i * BA_CELLS, 0, null_name(), bh + i,
            )
            if rc != 0:
                burst_spawn_fail += 1
            i += 1
        # Join every handle EXACTLY ONCE; the second join MUST hit the
        # frozen T** consumed-handle -EINVAL (zero silent double-joins).
        i = 0
        while i < BURST_N:
            bstat[i] = -1
            if probe_join(bh + i, bstat + i) == 0 and bstat[i] == 0:
                joined_total += 1
                if slots[i * 2] != Int64(b + 1):
                    lost_wakes += 1  # never observed its release generation
                if slots[i * 2 + 1] != 1:
                    churn_bad += 1
                # join is the sync point: the leave-bound destructor has
                # fired by now and must have incremented this payload once.
                if payloads[i] != 1:
                    dtor_misses += 1
                var dstat = stack_allocation[1, Int64]()
                dstat[0] = -1
                if probe_join(bh + i, dstat) == RC_EINVAL:
                    double_join_ok += 1
                else:
                    churn_bad += 1  # double join did NOT raise determinately
            else:
                churn_bad += 1
            i += 1
        b += 1

    var exp_burst_threads = bursts * BURST_N
    print(
        "S2-STRESS burst ledger: joined=", joined_total,
        "/", exp_burst_threads, " double_join_einval=", double_join_ok,
        " lost_wakes=", lost_wakes, " churn_bad=", churn_bad,
        " dtor_misses=", dtor_misses,
        " spawn_fail=", burst_spawn_fail,
    )
    if joined_total != exp_burst_threads:
        failed += 1
        print(
            "S2-STRESS FAIL: burst joins ", joined_total,
            " != ", exp_burst_threads,
        )
    if lost_wakes != 0:
        failed += 1
        print("S2-STRESS FAIL: lost barrier wakes: ", lost_wakes)
    if double_join_ok != exp_burst_threads:
        failed += 1
        print(
            "S2-STRESS FAIL: double-join -EINVAL count ", double_join_ok,
            " != ", exp_burst_threads,
        )
    if churn_bad != 0:
        failed += 1
        print("S2-STRESS FAIL: burst churn/join anomalies: ", churn_bad)
    if dtor_misses != 0:
        failed += 1
        print("S2-STRESS FAIL: missing burst destructor firings: ", dtor_misses)
    if burst_spawn_fail != 0:
        failed += 1
        print("S2-STRESS FAIL: burst spawn failures: ", burst_spawn_fail)

    # Key teardown: every binding was drained above (POSIX: a destructor does
    # not fire for values still bound at key destruction — the exact
    # reconciliation already proves none remain).
    try:
        key.destroy()
    except e:
        failed += 1
        print("S2-STRESS FAIL: key.destroy raised: ", String(e))

    if failed == 0:
        print(
            "S2-STRESS PASS: ",
            exp_rounds, " storm children across", WRITERS, " writers;",
            " ", exp_burst_threads, " barrier-burst threads;",
            " ledger reconciled EXACTLY; zero lost wakes; zero double-joins",
        )
        print("RESULT: s2-stress green")
    else:
        print("RESULT: s2-stress FAIL (", failed, " checks)")
        c_exit(Int32(1))
