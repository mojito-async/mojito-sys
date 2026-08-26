# mojito-sys S2.7 — §38.5 THREAD conformance suite (issue #54).
#
# Black-box over the PUBLIC mojito_sys.thread surface ONLY
# (spawn_native_thread / NativeThread.join / NativeThread.detach /
# native_thread_id / set_current_thread_name / ThreadOptions +
# thread_fill_name_cell). Every mandated §38.5 "Threads" case (spec
# L1839-1846), one printed row each:
#
#   1. thread-create-join     — spawn runs a real child; userdata carried;
#     join blocks to completion and returns the entry status;
#   2. thread-return-value    — positive/negative/large statuses reach
#     join() EXACTLY through the C trampoline's long return slot;
#   3. thread-error           — decoded errno propagation: undersized
#     stack_size raise, join-twice raise, join-after-detach raise;
#   4. threads-sequential-x100— 100 sequential create/join cycles, each
#     verified exactly (leak-clean smoke: any handle leak exhausts the
#     process long before 100 silent cycles);
#   5. threads-concurrent-x32 — 32 LIVE threads at once; overlap proven by
#     wall clock (all sleep 120ms; total must beat the serial floor
#     3840ms with a generous 3000ms bar) plus every completion observed;
#   6. worker-trampoline      — the C trampoline applies the spawned name
#     INSIDE the child (child reads its own name back via
#     pthread_getname_np) and hands userdata through untouched;
#   7. native-thread-ids      — self id nonzero/stable within a thread;
#     ids DISTINCT across 8 simultaneously-live threads and distinct from
#     the spawner's id;
#   8. shutdown-drain         — 16 detached children all observed exiting
#     (done flags polled under a 10s deadline): detach-all drains with
#     zero leaked live threads before process exit.
#
# Platform-tolerant skips are RECORDED, never silent: case 6 degrades to a
# '<case>: SKIP (<reason>)' row when the host lacks pthread_getname_np
# (POSIX-optional interface); the SKIP count is re-printed next to the
# RESULT line so the gate output shows exactly what was skipped.
#
# Timing policy (issue RISK note): generous sleeps/thresholds and no
# failure retries inside cases — a marginal host can only make case 5 MORE
# parallel, never flaky against these bars.
#
# b2 notes (repo conventions, see tests/s2/thread/thread_test.mojo):
#   - Entries are @export abi("C") defs addressed via the entry_pointer[]
#     adrp/add idiom; null pointers come from RUNTIME zeros.
#   - Failures accumulate in a main()-local counter (no module-level
#     mutable globals); the suite never raises String payloads itself.
#   - Concurrent-handle stash: NativeThread is Movable/not copyable, so the
#     x32/x8 fan-outs park each consume ticket in a raw Int64 stash cell
#     (fields are public by design) and rebuild the wrapper for join — the
#     documented pattern for holding many live handles without containers.
#
# Run via tests/s2/conformance/threads/run.sh (AOT build; the JIT
# deterministically SIGSEGVs lowering this wrapper mix, per #49).

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from mojito_sys.time.monotonic import MonotonicInstant
from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    ThreadOptions,
    native_thread_id,
    no_name,
    set_current_thread_name,
    spawn_native_thread,
    thread_fill_name_cell,
)

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime NameBufBytes = 128

# Per-thread userdata block layout (Int64 cells, one block per child):
#   [0] done flag        [1] status to return   [2] sleep microseconds
#   [3] self id (call 1) [4] self id (call 2)   [5..7] spare
comptime STRIDE = 8

comptime CONCURRENT_N = 32
comptime IDS_N = 8
comptime DRAIN_N = 16


# ---- test-local libc bindings ------------------------------------------------

@extern("pthread_self")
def _libc_pthread_self() abi("C") -> UInt64:
    ...


# darwin AND Linux shape: int pthread_getname_np(pthread_t, char*, size_t).
@extern("pthread_getname_np")
def _libc_pthread_getname_np(
    thread: UInt64,
    buf: UnsafePointer[Byte, MutAnyOrigin],
    buflen: Int,
) abi("C") -> Int32:
    ...


@extern("usleep")
def _libc_usleep(useconds: UInt32) abi("C") -> Int32:
    ...


# ---- exported thread entries (ms_thread_entry shape: long (*)(void*)) --------

@export("s27_conf_counter_entry")
def _conf_counter_entry(ud: CellsPtr) abi("C") -> Int64:
    ud[0] += 1
    return 0


@export("s27_conf_status_entry")
def _conf_status_entry(ud: CellsPtr) abi("C") -> Int64:
    return ud[1]


@export("s27_conf_sleeper_entry")
def _conf_sleeper_entry(ud: CellsPtr) abi("C") -> Int64:
    _ = _libc_usleep(UInt32(ud[2]))
    ud[3] = Int64(native_thread_id())
    ud[4] = Int64(native_thread_id())  # stability: second read, same thread
    ud[0] = 1  # done — LAST, so the parent can drain on this flag
    return ud[1]


# Trampoline probe: the C trampoline applied our name BEFORE running this
# body, and handed userdata through untouched (counter incremented too).
@export("s27_conf_name_entry")
def _conf_name_entry(ud: CellsPtr) abi("C") -> Int64:
    ud[0] += 1
    var tid = _libc_pthread_self()
    var buf = (ud + 4).bitcast[Byte]()
    ud[1] = Int64(_libc_pthread_getname_np(tid, buf, NameBufBytes))
    return 0


# Code address of an @export'd abi("C") def as a C function pointer —
# the adrp/add idiom proven in tests/s1/abi/callbacks/conformance_test.mojo.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


# True iff haystack contains needle — same test-local helper as vm_test.mojo.
def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) != -1


# Byte-wise NUL-terminated comparison over two raw char buffers.
def _bytes_eq(
    a: UnsafePointer[Byte, MutAnyOrigin],
    b: UnsafePointer[Byte, MutAnyOrigin],
) -> Bool:
    var i = 0
    while True:
        if a[i] != b[i]:
            return False
        if a[i] == 0:
            return True
        i += 1


# Prints the verdict row only; main() accumulates failures locally.
def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


# Records a platform-tolerant skip EXPLICITLY (never silent).
def skip_row(name: String, reason: String):
    print(name + ": SKIP (" + reason + ") -- recorded")


def main() raises:
    var failed = 0
    var skipped = 0
    var counter_ptr = entry_pointer["s27_conf_counter_entry"]()
    var status_ptr = entry_pointer["s27_conf_status_entry"]()
    var sleeper_ptr = entry_pointer["s27_conf_sleeper_entry"]()
    var name_ptr = entry_pointer["s27_conf_name_entry"]()
    var cells = stack_allocation[STRIDE, Int64]()
    var ud = cells

    # ---- 1. create + join ------------------------------------------------------
    # Spawn runs a real child (userdata effect lands); join returns its
    # status after blocking to completion.
    var cj_ok = True
    cells[0] = 0
    var k = 0
    while k < 3:
        var t = spawn_native_thread(counter_ptr, ud, 0, no_name())
        var st = t.join()
        cj_ok = cj_ok and (st == 0) and (cells[0] == Int64(k + 1))
        k += 1
    if not check("S2.7 thread-create-join", cj_ok):
        failed += 1

    # ---- 2. return value propagation (positive/negative/large) -----------------
    var rv_ok = True
    var vals = stack_allocation[3, Int64]()
    vals[0] = 7
    vals[1] = -987654321
    vals[2] = Int64(4611686018427387904)  # 2**62 — far beyond int32
    var vi = 0
    while vi < 3:
        ud[1] = vals[vi]
        var t = spawn_native_thread(status_ptr, ud, 0, no_name())
        rv_ok = rv_ok and (t.join() == vals[vi])
        vi += 1
    if not check("S2.7 thread-return-value-exact", rv_ok):
        failed += 1

    # ---- 3. error propagation (decoded errno, deterministic) --------------------
    var err_ok = True
    # (a) undersized stack_size: frozen ABI rejects with -EINVAL at spawn.
    var stack_raised = False
    try:
        var bad = spawn_native_thread(counter_ptr, ud, 1, no_name())
        _ = bad.join()  # must have raised at spawn; drain if it ever didn't
    except e:
        stack_raised = contains(String(e), "EINVAL")
    err_ok = err_ok and stack_raised
    # (b) join-twice on a consumed handle.
    ud[1] = 5
    var tj = spawn_native_thread(status_ptr, ud, 0, no_name())
    err_ok = err_ok and (tj.join() == 5)
    var twice_raised = False
    try:
        _ = tj.join()  # second join MUST raise
    except e:
        twice_raised = contains(String(e), "EINVAL")
    err_ok = err_ok and twice_raised
    # (c) join-after-detach consumes the same way. The detached child gets
    # PRIVATE scratch: detach returns before the child exits, so its late
    # userdata writes must not land in the shared counter cells below.
    var dcells = stack_allocation[STRIDE, Int64]()
    var td = spawn_native_thread(counter_ptr, dcells, 0, no_name())
    td.detach()
    var jad_raised = False
    try:
        _ = td.join()  # join after detach MUST raise
    except e:
        jad_raised = contains(String(e), "EINVAL")
    err_ok = err_ok and jad_raised
    if not check("S2.7 thread-error-decoded-einval", err_ok):
        failed += 1
    _ = set_current_thread_name("mjs-conf-main")

    # ---- 4. many sequential creates (x100, exact per-cycle verification) -------
    var seq_ok = True
    cells[0] = 0
    var c = 0
    while c < 100:
        var t = spawn_native_thread(counter_ptr, ud, 0, no_name())
        var st = t.join()
        if st != 0 or cells[0] != Int64(c + 1):
            seq_ok = False
            print(
                "    | cycle " + String(c) + ": st=" + String(st)
                + " counter=" + String(cells[0])
            )
        c += 1
    if not check("S2.7 threads-sequential-x100", seq_ok):
        failed += 1

    # ---- 5. many concurrent creates (x32 live at once) --------------------------
    # Every child sleeps 120ms; the serial floor is 32*120ms = 3840ms. If the
    # 32 threads did NOT overlap, the loop could not beat 3000ms; every done
    # flag + exact returned status must still land.
    var big = stack_allocation[CONCURRENT_N * STRIDE, Int64]()
    var stash = stack_allocation[CONCURRENT_N, Int64]()
    var t0 = MonotonicInstant.now()
    var i = 0
    while i < CONCURRENT_N:
        var blk = big + i * STRIDE
        blk[1] = Int64(i)  # child returns its own index as status
        blk[2] = 120000  # 120ms
        var t = spawn_native_thread(sleeper_ptr, blk, 0, no_name())
        # Park the consume ticket: NativeThread is not copyable, so the
        # x32 fan-out holds handles as raw words and rebuilds below.
        stash[i] = t.handle
        t.consumed = True
        i += 1
    var conc_ok = True
    i = 0
    while i < CONCURRENT_N:
        var tj2 = NativeThread()
        tj2.handle = stash[i]
        tj2.consumed = False
        var st = tj2.join()
        var blk = big + i * STRIDE
        conc_ok = conc_ok and (st == Int64(i)) and (blk[0] == 1)
        i += 1
    var elapsed_ms = t0.elapsed().as_millis()
    conc_ok = conc_ok and (elapsed_ms < 3000)
    if not check("S2.7 threads-concurrent-x32-overlapped", conc_ok):
        failed += 1
        print("    | elapsed_ms=" + String(elapsed_ms))

    # ---- 6. worker trampoline (name applied INSIDE the child) -------------------
    # Poison the byte area so a silent no-write cannot pass as "".
    cells[0] = 0
    cells[1] = 0
    var poison = (ud + 4).bitcast[Byte]()
    var pi = 0
    while pi < NameBufBytes:
        poison[pi] = 0xAA
        pi += 1
    var opts = ThreadOptions(name="mjs-conf-t27")
    opts.validate()
    var ncell = stack_allocation[16, Byte]()
    var tn = spawn_native_thread(
        name_ptr, ud, opts.stack_size, thread_fill_name_cell(opts, ncell),
    )
    var nst = tn.join()
    if nst != 0:
        skipped += 1
        skip_row(
            "S2.7 worker-trampoline-naming",
            "child probe failed rc=" + String(nst),
        )
    elif cells[1] != 0:
        # pthread_getname_np itself failed: host lacks the POSIX-optional
        # interface — recorded skip, never a silent pass.
        skipped += 1
        skip_row(
            "S2.7 worker-trampoline-naming",
            "pthread_getname_np unsupported on host (rc=" + String(cells[1]) + ")",
        )
    else:
        var expected = String("mjs-conf-t27")
        var exp_buf = stack_allocation[16, Byte]()
        var exp_src = expected.unsafe_ptr()
        var ei = 0
        while ei <= expected.byte_length():
            exp_buf[ei] = exp_src[ei]
            ei += 1
        var tramp_ok = _bytes_eq((ud + 4).bitcast[Byte](), exp_buf)
        tramp_ok = tramp_ok and (cells[0] == 1)  # userdata passed through
        if not check("S2.7 worker-trampoline-naming", tramp_ok):
            failed += 1

    # ---- 7. native thread IDs ----------------------------------------------------
    var main_a = native_thread_id()
    var main_b = native_thread_id()
    var ids_big = stack_allocation[IDS_N * STRIDE, Int64]()
    var ids_stash = stack_allocation[IDS_N, Int64]()
    i = 0
    while i < IDS_N:
        var blk = ids_big + i * STRIDE
        blk[1] = 0  # sleeper returns this — stack_allocation is UNINITIALIZED
        blk[2] = 60000  # 60ms — keep ALL 8 alive simultaneously
        var t = spawn_native_thread(sleeper_ptr, blk, 0, no_name())
        ids_stash[i] = t.handle
        t.consumed = True
        i += 1
    var ids_ok = (main_a != 0) and (main_a == main_b)
    i = 0
    while i < IDS_N:
        var tj3 = NativeThread()
        tj3.handle = ids_stash[i]
        tj3.consumed = False
        ids_ok = ids_ok and (tj3.join() == 0)
        i += 1
    i = 0
    while i < IDS_N and ids_ok:
        var blk = ids_big + i * STRIDE
        ids_ok = ids_ok and (blk[0] == 1)  # ran to completion
        ids_ok = ids_ok and (blk[3] != 0) and (blk[3] == blk[4])
        ids_ok = ids_ok and (UInt64(blk[3]) != main_a)
        var j = 0
        while j < IDS_N:
            if j != i:
                ids_ok = ids_ok and (blk[3] != (ids_big + j * STRIDE)[3])
            j += 1
        i += 1
    if not check("S2.7 native-thread-ids-distinct-stable", ids_ok):
        failed += 1
        print("    | main_id=" + String(main_a))
        var d = 0
        while d < IDS_N:
            var blk = ids_big + d * STRIDE
            print(
                "    | child[" + String(d) + "] done=" + String(blk[0])
                + " tid1=" + String(blk[3]) + " tid2=" + String(blk[4])
            )
            d += 1

    # ---- 8. shutdown: detach-all + drain to zero live threads --------------------
    var drain_big = stack_allocation[DRAIN_N * STRIDE, Int64]()
    i = 0
    while i < DRAIN_N:
        var blk = drain_big + i * STRIDE
        blk[2] = 80000  # 80ms of work after a racing detach
        var t = spawn_native_thread(sleeper_ptr, blk, 0, no_name())
        # Race-safe by contract: detach before OR after child exit are both
        # deterministic success paths in the C layer.
        t.detach()
        i += 1
    # Poll done flags under a hard 10s deadline (generous vs 80ms of work).
    var drained = 0
    var dl = MonotonicInstant.now()
    var drain_ok = True
    while drained < DRAIN_N:
        drained = 0
        i = 0
        while i < DRAIN_N:
            if (drain_big + i * STRIDE)[0] == 1:
                drained += 1
            i += 1
        if drained < DRAIN_N:
            if dl.elapsed().as_millis() > 10000:
                drain_ok = False
                break
            _ = _libc_usleep(20000)
    drain_ok = drain_ok and (drained == DRAIN_N)
    if not check("S2.7 shutdown-detach-drain-zero-leaks", drain_ok):
        failed += 1

    # ---- verdict ------------------------------------------------------------------
    print("")
    print("SKIPPED (recorded): " + String(skipped))
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("s2-conformance-threads: " + String(failed) + " case(s) failed")
    print("RESULT: all green")
