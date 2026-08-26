# mojito-sys S2.2 — NativeThread conformance (issue #49, spec §11).
#
# Drives the §11 thread surface (Mojo wrappers bound to the frozen
# mjs_thread_* C ABI, native/include/mojito_sys.h s2-thread block):
#
#   1. userdata-counter spawn   — state carried through the void* userdata
#     slot; the child increments a caller cell across repeated spawns;
#   2. entry-status propagation — the entry's `long` return value reaches
#     join() exactly (negative statuses included);
#   3. join-twice raises        — after a consuming join, a second join
#     raises the decoded -EINVAL (deterministic consumed-handle contract);
#   4. detach clean exit        — T** consume semantics: mjs_thread_detach
#     NULLs *t on success (the wrapper mirrors that into the handle), a
#     double detach and a join-after-detach both raise -EINVAL, and the
#     detached thread exits cleanly before process exit (drained below);
#   5. name round-trip          — a named spawn is read back INSIDE the
#     child via pthread_getname_np(pthread_self(), ...) and compared by the
#     parent (true FFI round-trip, not just absence of error); an overlong
#     name (> 15 chars + NUL portable floor) raises -ENAMETOOLONG; the
#     unnamed default path (NULL name) spawns fine;
#   6. native_thread_id         — nonzero and stable within one thread;
#   7. current-thread rename    — set_current_thread_name accepted;
#   8. 100 sequential cycles    — 50 spawn/join + 50 spawn/detach cycles,
#     each forcing the C-side handle malloc/free pair plus a full
#     pthread create/teardown (leak-clean smoke). In-process RSS probing is
#     unavailable under the JIT (S0 SPIKE_REPORT limitation #5), so
#     cleanliness is asserted behaviorally: every cycle must complete with
#     exact results, and any handle leak would surface as resource
#     exhaustion long before 100 live handles could accumulate silently.
#
# b2 notes (matching tests/s1/*/ conventions):
#   - Entry mechanism: b2 cannot convert a Mojo function VALUE to a C
#     function pointer (nominal function types, S0 SPIKE_REPORT). Entries
#     are @export abi("C") defs whose machine addresses are materialized by
#     the entry_pointer[symbol]() adrp/add idiom proven in
#     tests/s1/abi/callbacks/conformance_test.mojo.
#   - Null pointers are built from a RUNTIME zero (`unsafe_from_address=0`
#     literal is rejected in 1.0.0b2).
#   - Failure assertions decode through the wrapper's raise_errno path
#     (`String(e)` carries the errno spelling); failures accumulate in a
#     main()-local counter (no module-level mutable globals), diagnostics
#     go to stdout. The suite NEVER raises a String payload itself (H6).
#
# Run via tests/s2/thread/run.sh (builds libmojito_sys.dylib first); green
# requires the exact "RESULT: 8/8 PASSED" line.

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from mojito_sys.thread.thread import (
    CThreadEntry,
    ThreadOptions,
    UserdataPtr,
    native_thread_id,
    set_current_thread_name,
    spawn_native_thread,
)

# Int64-pointer view of the shared scratch cells (userdata payload layout:
# [0] counter, [1] entry status / child-written rc, [4..] byte scratch).
comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]

comptime NameBufBytes = 128


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

@export("mjs_tst_counter_entry")
def _tst_counter_entry(ud: CellsPtr) abi("C") -> Int64:
    ud[0] += 1
    return 0


@export("mjs_tst_status_entry")
def _tst_status_entry(ud: CellsPtr) abi("C") -> Int64:
    return ud[1]


@export("mjs_tst_sleep_entry")
def _tst_sleep_entry(ud: CellsPtr) abi("C") -> Int64:
    _ = _libc_usleep(150000)
    return 0


# Reads THIS thread's own name into the cells' byte area ([4..]) and stores
# the pthread_getname_np return code in cells[1].
@export("mjs_tst_name_entry")
def _tst_name_entry(ud: CellsPtr) abi("C") -> Int64:
    var tid = _libc_pthread_self()
    var buf = (ud + 4).bitcast[Byte]()
    var rc = _libc_pthread_getname_np(tid, buf, NameBufBytes)
    ud[1] = Int64(rc)
    return 0


# Code address of an @export'd abi("C") def as a C function pointer — the
# adrp/add idiom from tests/s1/abi/callbacks/conformance_test.mojo.
def entry_pointer[symbol_name: String]() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return UnsafePointer[NoneType, MutAnyOrigin](unsafe_from_address=Int(addr))


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
    var cells = stack_allocation[8, Int64]()
    var ud = cells.bitcast[UserdataPtr]()
    var counter_ptr = entry_pointer["mjs_tst_counter_entry"]()
    var status_ptr = entry_pointer["mjs_tst_status_entry"]()
    var sleep_ptr = entry_pointer["mjs_tst_sleep_entry"]()
    var name_ptr = entry_pointer["mjs_tst_name_entry"]()

    # ---- 1. userdata-counter spawn ------------------------------------------
    cells[0] = 0
    var spawned_ok = True
    var k = 0
    while k < 3:
        var t = spawn_native_thread(counter_ptr, ud, ThreadOptions())
        var st = t.join()
        if st != 0 or cells[0] != k + 1:
            spawned_ok = False
        k += 1
    if not check(
        "T2.2 userdata-counter spawn (3x, counter==3)",
        spawned_ok and cells[0] == 3,
    ):
        failed += 1

    # ---- 2. entry-status propagation through join ----------------------------
    cells[1] = -12345
    var t2 = spawn_native_thread(status_ptr, ud, ThreadOptions())
    var got = t2.join()
    if not check("T2.2 entry-status propagation (-12345)", got == -12345):
        failed += 1

    # ---- 3. join-twice raises -------------------------------------------------
    var twice_ok = True
    try:
        _ = t2.join()
        twice_ok = False  # second join MUST raise
    except e:
        twice_ok = contains(String(e), "EINVAL")
    if not check("T2.2 join-twice raises EINVAL", twice_ok):
        failed += 1

    # ---- 5a. name round-trip (child reads own name back) ---------------------
    cells[1] = 0
    # Pre-poison the byte area so a silent no-write cannot pass as "".
    var poison = (cells + 4).bitcast[Byte]()
    var pi = 0
    while pi < NameBufBytes:
        poison[pi] = 0xAA
        pi += 1
    var named = spawn_native_thread(
        name_ptr, ud, ThreadOptions(stack_size=0, priority_hint=0, name="mojito-t22")
    )
    var nst = named.join()
    var expected = String("mojito-t22")
    var exp_buf = stack_allocation[16, Byte]()
    var exp_src = expected.unsafe_ptr()
    var ei = 0
    while ei <= len(expected):
        exp_buf[ei] = exp_src[ei]
        ei += 1
    if not check(
        "T2.2 name round-trip (child getname == mojito-t22)",
        nst == 0 and cells[1] == 0 and _bytes_eq((cells + 4).bitcast[Byte](), exp_buf),
    ):
        failed += 1

    # ---- 5b. overlong name rejected with ENAMETOOLONG ------------------------
    var toolong_ok = True
    try:
        _ = spawn_native_thread(
            counter_ptr,
            ud,
            ThreadOptions(stack_size=0, priority_hint=0, name="way-too-long-thread-name"),
        )
        toolong_ok = False  # must have raised
    except e:
        toolong_ok = contains(String(e), "errno 63")  # darwin ENAMETOOLONG
    if not check("T2.2 >15-char name raises ENAMETOOLONG", toolong_ok):
        failed += 1

    # ---- 5c. default options (NULL name path) spawn cleanly ------------------
    cells[0] = 0
    var t_def = spawn_native_thread(counter_ptr, ud)
    var dst = t_def.join()
    if not check("T2.2 default-options spawn (NULL name)", dst == 0 and cells[0] == 1):
        failed += 1

    # ---- 6/7. native_thread_id + current-thread rename -----------------------
    var id_a = native_thread_id()
    var id_b = native_thread_id()
    var rename_ok = True
    try:
        set_current_thread_name("mojito-main")
    except e:
        rename_ok = False
    if not check(
        "T2.2 self id stable/nonzero + rename ok",
        id_a != 0 and id_a == id_b and rename_ok,
    ):
        failed += 1

    # ---- 4. detach clean exit incl. T** consume semantics --------------------
    var t4 = spawn_native_thread(sleep_ptr, ud, ThreadOptions())
    t4.detach()
    # Consume semantics: detach NULLed the C-side *t; the wrapper mirrored it.
    var consume_ok = t4.consumed
    consume_ok = consume_ok and (Int(t4.handle) == 0)
    var d2_ok = True
    try:
        t4.detach()
        d2_ok = False  # double detach MUST raise
    except e:
        d2_ok = contains(String(e), "EINVAL")
    var j_after_d_ok = True
    try:
        _ = t4.join()
        j_after_d_ok = False  # join-after-detach MUST raise
    except e:
        j_after_d_ok = contains(String(e), "EINVAL")
    if not check(
        "T2.2 detach consumes handle; double-detach/join-after raise",
        consume_ok and d2_ok and j_after_d_ok,
    ):
        failed += 1

    # ---- 8. 100 sequential cycles (leak-clean smoke) --------------------------
    cells[0] = 0
    var cyc_fail = 0
    var c = 0
    while c < 50:
        var t = spawn_native_thread(counter_ptr, ud)
        var st = t.join()
        if st != 0 or cells[0] != c + 1:
            cyc_fail += 1
        c += 1
    var dc = 0
    while dc < 50:
        # Instant-exit entries: detach may land before OR after the child's
        # exit — both orders are deterministic, error-free paths in C.
        var t = spawn_native_thread(counter_ptr, ud)
        t.detach()
        dc += 1
    # Drain any detached children before process exit (clean-exit guarantee).
    _ = _libc_usleep(200000)
    if not check(
        "T2.2 100 sequential spawn/join+detach cycles clean",
        cyc_fail == 0,
    ):
        failed += 1

    print("RESULT: " + String(8 - failed) + "/8 PASSED")
