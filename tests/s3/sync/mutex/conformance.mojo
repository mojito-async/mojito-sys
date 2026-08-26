# mojito-sys S3.1 — NativeMutex conformance (issue #57, spec §15).
#
# Drives the §15 mutex surface (Mojo wrapper bound to the frozen
# mjs_mutex_* C ABI, native/include/mojito_sys.h s3-mutex block):
#
#   1. init + lock/unlock roundtrip — create() adopts the C handle,
#     lock() then unlock() succeed twice in a row, destroy() consumes;
#   2. try_lock busy/free handshake — try_lock on a HELD mutex returns
#     False (deterministic: pthread mutexes are non-recursive, so the
#     holder itself observes -EBUSY) and on a FREE mutex True; the
#     CROSS-THREAD half of the handshake (second thread sees False while
#     the first holds, True once released) lives in mutex_smoke.c via
#     raw pthreads — an @export'd C-ABI entry cannot legally propagate
#     the wrapper's `raises`, so a child-side try_lock through the
#     wrapper is uncompilable there. The 8-thread contention test below
#     still drives lock/unlock through the WRAPPER across real OS
#     threads.
#   3. contention stress — 8 spawned threads x 10k guarded increments
#     == 80000 EXACTLY (no lost updates through the wrapper);
#   4. use-after-destroy raises — lock()/unlock() on a consumed mutex
#     raise the decoded -EINVAL WITHOUT re-entering C;
#   5. double destroy raises — the second destroy() raises -EINVAL;
#   6. try_lock after destroy raises — the busy path also surfaces the
#     decoded errno as a raise (only genuine contention maps to False).
#
# b2 notes (matching tests/s2/thread/thread_test.mojo conventions):
#   - Failure assertions decode through raise_errno (`String(e)` carries
#     the errno spelling); failures accumulate in a main()-local counter
#     (no module-level mutable globals). The suite never raises a String
#     payload itself (H6).
#   - Thread handles travel through stack-carved cells and are
#     re-adopted for joining (fields are public by design, mirroring
#     NativeThread).
#
# Run via tests/s3/sync/mutex/run.sh (builds libmojito_sys.dylib first);
# green requires the exact "RESULT: 6/6 PASSED" line.

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from mojito_sys.sync.mutex import NativeMutex
from mojito_sys.thread.thread import (
    CThreadEntry,
    NativeThread,
    UserdataPtr,
    no_name,
    spawn_native_thread,
)

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]

# Stress shape (spec acceptance): THREADS workers x ITERATIONS guarded
# increments, counter cell shared at ud[3].
comptime THREADS = 8
comptime ITERATIONS = 10_000


# ---- exported thread entries (ms_thread_entry shape: long (*)(void*)) --------

@export("mjs_s31_stress_entry")
def _stress_entry(ud: CellsPtr) abi("C") -> Int64:
    # ud[0] = live mutex handle, ud[1] = iterations, ud[3] = counter.
    # The wrapper's lock/unlock raise on genuine errors; a C-ABI export
    # cannot propagate exceptions, so the (never-taken) error path is
    # trapped and reported through the entry status instead. With a live
    # handle neither call ever raises at runtime.
    var m = NativeMutex()
    m.handle = ud[0]
    m.destroyed = False
    var n = Int(ud[1])
    var i = 0
    while i < n:
        try:
            m.lock()
            ud[3] += 1
            m.unlock()
        except:
            return -1
        i += 1
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


# True iff haystack contains needle (String.find returns -1 on miss) —
# same test-local helper as tests/s1/memory/vm/vm_test.mojo.
def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) != -1


# Prints the verdict row only; main() accumulates failures locally (b2
# forbids module-level mutable globals).
def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def main() raises:
    var failed = 0

    # ---- 1. init + lock/unlock roundtrip -------------------------------------
    var roundtrip_ok = True
    var m = NativeMutex.create()
    roundtrip_ok = roundtrip_ok and not m.destroyed
    m.lock()
    m.unlock()
    m.lock()  # immediately re-acquirable after unlock
    m.unlock()
    m.destroy()
    roundtrip_ok = roundtrip_ok and m.destroyed and m.handle == 0
    if not check("S3.1 init + lock/unlock roundtrip", roundtrip_ok):
        failed += 1

    # ---- 2. try_lock busy/free -------------------------------------------------
    var t = NativeMutex.create()
    t.lock()
    var held_false = not t.try_lock()  # self-held: non-recursive -> -EBUSY
    t.unlock()
    var free_true = t.try_lock()
    if free_true:
        t.unlock()
    t.destroy()
    if not check(
        "S3.1 try_lock False-when-held / True-when-free",
        held_false and free_true,
    ):
        failed += 1

    # ---- 3. contention stress: 8 threads x 10k == 80000 -----------------------
    var args = stack_allocation[4, Int64]()
    var handles = stack_allocation[THREADS, Int64]()
    args[0] = 0
    args[1] = Int64(ITERATIONS)
    args[3] = 0  # guarded counter
    var stress_ok = True
    var sm = NativeMutex.create()
    args[0] = sm.handle
    var stress_entry = entry_pointer["mjs_s31_stress_entry"]()
    var i = 0
    while i < THREADS:
        # Spawn ALL workers before joining any so they genuinely overlap.
        var w = spawn_native_thread(stress_entry, args, 0, no_name())
        handles[i] = w.handle
        i += 1
    i = 0
    while i < THREADS:
        var w = NativeThread()
        w.handle = handles[i]
        w.consumed = False
        var st = w.join()
        if st != 0:
            stress_ok = False
        i += 1
    stress_ok = stress_ok and (args[3] == Int64(THREADS * ITERATIONS))
    sm.destroy()
    if not check(
        "S3.1 contention stress 8x10k guarded increments == 80000",
        stress_ok,
    ):
        failed += 1

    # ---- 4. use-after-destroy raises ------------------------------------------
    var d = NativeMutex.create()
    d.destroy()
    var uad_lock_ok = True
    try:
        d.lock()
        uad_lock_ok = False  # must have raised
    except e:
        uad_lock_ok = contains(String(e), "EINVAL")
    var uad_unlock_ok = True
    try:
        d.unlock()
        uad_unlock_ok = False  # must have raised
    except e:
        uad_unlock_ok = contains(String(e), "EINVAL")
    if not check(
        "S3.1 lock/unlock after destroy raise EINVAL",
        uad_lock_ok and uad_unlock_ok,
    ):
        failed += 1

    # ---- 5. double destroy raises ----------------------------------------------
    var dd_ok = True
    try:
        d.destroy()
        dd_ok = False  # second destroy MUST raise
    except e:
        dd_ok = contains(String(e), "EINVAL")
    if not check("S3.1 double destroy raises EINVAL", dd_ok):
        failed += 1

    # ---- 6. try_lock after destroy raises --------------------------------------
    var tl_dead_ok = True
    try:
        _ = d.try_lock()
        tl_dead_ok = False  # must have raised, NOT returned False
    except e:
        tl_dead_ok = contains(String(e), "EINVAL")
    if not check("S3.1 try_lock after destroy raises EINVAL", tl_dead_ok):
        failed += 1

    print("RESULT: " + String(6 - failed) + "/6 PASSED")
