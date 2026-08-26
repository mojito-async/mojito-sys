# mojito-sys S2.7 — §38.5 TLS conformance suite (issue #54).
#
# Black-box over the PUBLIC mojito_sys.thread surface ONLY: thread legs
# spawn through mojito_sys.thread.thread (NativeThread over mjs_thread_*),
# TLS legs drive NativeTlsKey (mojito_sys.thread.tls) — including INSIDE
# spawned child entries — the NativeThread-driven counterpart to the
# raw-pthread cross-check in tests/s2/thread/tls_test.mojo. Every mandated
# §38.5 "TLS" case (spec L1848-1853), one printed row each:
#
#   1. tls-set-get            — unset reads null; bind/read; overwrite;
#     explicit rebind-to-null clears;
#   2. tls-per-thread-isolation — worker threads (NativeThread-spawned)
#     bind their OWN values under a shared key; neither side observes the
#     other's binding after join;
#   3. tls-destructor-once    — a registered destructor fires EXACTLY ONCE
#     at each binding thread's exit (POSIX pthread_key dtor semantics);
#   4. tls-repeated-reuse     — 10 sequential spawns of the SAME entry on
#     the SAME key: every fresh OS thread starts UNBOUND (initial read is
#     null — no state bleeds across thread reuse), binds its own payload,
#     and the per-exit dtor lands exactly once per payload;
#   5. tls-ctx-switch-retains — the SAME value is retained across a
#     same-thread synthetic context switch (spike ms_ctx pair, spec
#     L1860). Platform-tolerant: hosts without the spike synthetic-stack
#     backend record an explicit '<case>: SKIP (<reason>)' row.
#
# Skips are RECORDED, never silent; the SKIP count is re-printed next to
# the RESULT line.
#
# b2 notes (repo conventions, see tests/s2/thread/{thread,tls}_test.mojo):
#   - Entries are @export abi("C") defs addressed via the spike
#     entry_pointer[] idiom; null pointers come from RUNTIME zeros.
#   - Child bodies never let raises escape across the C boundary: set()
#     failures are caught INTO the result cells.
#   - Destructor accounting lives in the bound payload cell, NOT in a
#     global (first-consumer contract, spec L888-893).
#
# Run via tests/s2/conformance/tls/run.sh (JIT run with bounded retry,
# mirroring tests/s2/thread/run_tls.sh).

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

from mojito_spike import (
    BytePtr,
    MS_CTX_SIZE,
    entry_pointer,
    ms_ctx_make,
    ms_ctx_switch,
    ms_stack_alloc,
    ms_stack_free,
)
from mojito_sys.thread.thread import (
    CThreadEntry,
    spawn_native_thread,
    no_name,
)
from mojito_sys.thread.tls import (
    NativeTlsKey,
    TlsDtorPtr,
    TlsValuePtr,
    create_tls_key,
)

comptime CellsPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime STACK_BYTES = 262144
comptime REUSE_N = 10

# Worker userdata block layout (Int64 cells):
#   [0] key id (UInt travels in one word: LP64 macOS arm64 + Linux x86_64)
#   [1] bind_addr (payload address to bind)
#   [2] set_ok    (1 after a successful set, 0 on raise)
#   [3] got_initial (raw get() address BEFORE binding — must be null)
#   [4] got_after   (raw get() address AFTER binding)
comptime WSTRIDE = 8


# --- small b2-safe helpers ------------------------------------------------------

def null_value() -> TlsValuePtr:
    var zero = 0
    return TlsValuePtr(unsafe_from_address=zero)


def ptr_at(a: Int) -> TlsValuePtr:
    return TlsValuePtr(unsafe_from_address=a)


def addr_of(p: TlsValuePtr) -> Int:
    return Int(p)


def cell_addr(p: CellsPtr) -> Int:
    return Int(p)


# Int64 view of a payload address for storing INTO / comparing against
# Int64 userdata cells (explicit conversions; no deprecated implicit
# Int -> Int64 edges).
def cell64(p: CellsPtr) -> Int64:
    return Int64(Int(p))


# Code address of an @export'd abi("C") def as a C function pointer
# (spike entry_pointer idiom). CThreadEntry / BytePtr / TlsDtorPtr are all
# UnsafePointer[Byte|NoneType, MutAnyOrigin] machine words; each use site
# bitcasts the pointee formality it needs.
def code_ptr[symbol_name: String]() -> BytePtr:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return BytePtr(unsafe_from_address=Int(addr))


def dtor_ptr[symbol_name: String]() -> TlsDtorPtr:
    return code_ptr[symbol_name]().bitcast[NoneType]()


def entry[symbol_name: String]() -> CThreadEntry:
    return code_ptr[symbol_name]()


def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def skip_row(name: String, reason: String):
    print(name + ": SKIP (" + reason + ") -- recorded")


# --- exported worker / destructor / switch bodies --------------------------------

# Destructor payload protocol: every bound value points at an Int64 cell;
# the destructor increments the cell it receives. Accounting lives in the
# payload, NOT in a global (first-consumer contract, spec L888-893).
@export("s27_conf_tls_counting_dtor")
def counting_dtor(value: BytePtr) abi("C"):
    var cell = value.bitcast[Int64]()
    cell[] = cell[] + 1


# Worker body (NativeThread-driven): under the shared key, verify this
# fresh OS thread starts UNBOUND, then bind its own payload and read it
# back. Raises NEVER cross the C boundary — caught into the result cells.
@export("s27_conf_tls_worker")
def tls_worker_entry(ud: CellsPtr) abi("C") -> Int64:
    var key = NativeTlsKey(UInt(ud[0]))
    ud[3] = Int64(addr_of(key.get()))  # initial read: fresh thread => null
    ud[2] = 0
    try:
        key.set(ptr_at(Int(ud[1])))
        ud[2] = 1
    except e:
        _ = e  # recorded as set_ok=0
    ud[4] = Int64(addr_of(key.get()))
    return 0


# Synthetic context switch pair (spike pattern): the alternate context
# yields straight back, so main crosses ONE suspend/resume cycle.
struct SwitchFrame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr

    def __init__(out self):
        var zero = 0
        self.self_ctx = BytePtr(unsafe_from_address=zero)
        self.back_ctx = BytePtr(unsafe_from_address=zero)


@export("s27_conf_switch_alt")
def switch_alt(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[SwitchFrame]()
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


# --- conformance -------------------------------------------------------------------

def main() raises:
    var failed = 0
    var skipped = 0

    # ---- 1. set/get round-trip incl. overwrite and clear ------------------------
    var k1 = create_tls_key(null_value())
    var pa = stack_allocation[1, Int64]()
    var pb = stack_allocation[1, Int64]()
    pa[] = 11
    pb[] = 22
    var rt_ok = addr_of(k1.get()) == 0  # unset -> null
    k1.set(ptr_at(cell_addr(pa)))
    rt_ok = rt_ok and (addr_of(k1.get()) == cell_addr(pa))
    k1.set(ptr_at(cell_addr(pb)))  # overwrite
    rt_ok = rt_ok and (addr_of(k1.get()) == cell_addr(pb))
    k1.set(null_value())  # explicit clear
    rt_ok = rt_ok and (addr_of(k1.get()) == 0)
    if not check("S2.7 tls-set-get-roundtrip", rt_ok):
        failed += 1

    # ---- 2+3. per-thread isolation + destructor-once over NativeThreads --------
    # Shared counting-dtor key; main keeps its own binding while two
    # sequentially-spawned workers each bind their own payload cell.
    var iso_key = create_tls_key(dtor_ptr["s27_conf_tls_counting_dtor"]())
    var main_payload = stack_allocation[1, Int64]()
    main_payload[] = 33
    iso_key.set(ptr_at(cell_addr(main_payload)))

    var w = stack_allocation[WSTRIDE, Int64]()
    var w_payload = stack_allocation[1, Int64]()
    w_payload[] = 0  # dtor counter starts at zero (incremented once at exit)
    w[0] = Int64(iso_key.key)
    w[1] = cell64(w_payload)
    var t1 = spawn_native_thread(
        entry["s27_conf_tls_worker"](), w, 0, no_name(),
    )
    var st1 = t1.join()

    var w2 = stack_allocation[WSTRIDE, Int64]()
    var w2_payload = stack_allocation[1, Int64]()
    w2_payload[] = 0  # dtor counter starts at zero
    w2[0] = Int64(iso_key.key)
    w2[1] = cell64(w2_payload)
    var t2 = spawn_native_thread(
        entry["s27_conf_tls_worker"](), w2, 0, no_name(),
    )
    var st2 = t2.join()

    var iso_ok = (st1 == 0) and (st2 == 0)
    iso_ok = iso_ok and (w[2] == 1) and (w2[2] == 1)
    iso_ok = iso_ok and (w[3] == 0) and (w2[3] == 0)  # fresh threads unbound
    iso_ok = iso_ok and (w[4] == cell64(w_payload))
    iso_ok = iso_ok and (w2[4] == cell64(w2_payload))
    # Main's own binding survived BOTH workers' sets on the same key id.
    iso_ok = iso_ok and (addr_of(iso_key.get()) == Int(cell64(main_payload)))
    if not check("S2.7 tls-per-thread-isolation", iso_ok):
        failed += 1
    # Destructor fired EXACTLY ONCE per worker exit (join is the sync
    # point); main's own binding is still live, so it has not fired yet.
    if not check(
        "S2.7 tls-destructor-once-at-exit",
        (w_payload[] == 1) and (w2_payload[] == 1),
    ):
        failed += 1
        print(
            "    | dtor counts: w=" + String(w_payload[])
            + " w2=" + String(w2_payload[])
        )

    # ---- 4. repeated thread reuse: fresh TLS state per new OS thread ------------
    var reuse_key = create_tls_key(dtor_ptr["s27_conf_tls_counting_dtor"]())
    var payloads = stack_allocation[REUSE_N, Int64]()
    var blocks = stack_allocation[REUSE_N * WSTRIDE, Int64]()
    var i = 0
    var reuse_ok = True
    while i < REUSE_N:
        payloads[i] = 0
        var blk = blocks + i * WSTRIDE
        blk[0] = Int64(reuse_key.key)
        blk[1] = cell64(payloads + i)
        var t = spawn_native_thread(entry["s27_conf_tls_worker"](), blk, 0, no_name())
        reuse_ok = reuse_ok and (t.join() == 0)
        reuse_ok = reuse_ok and (blk[2] == 1)
        reuse_ok = reuse_ok and (blk[3] == 0)  # fresh thread started unbound
        reuse_ok = reuse_ok and (blk[4] == cell64(payloads + i))
        # Dtor for THIS payload landed exactly once at its thread's exit.
        reuse_ok = reuse_ok and (payloads[i] == 1)
        i += 1
    if not check("S2.7 tls-repeated-thread-reuse-fresh-state", reuse_ok):
        failed += 1

    # ---- 5. SAME value retained across a same-thread context switch -------------
    var sentinel = stack_allocation[1, Int64]()
    sentinel[] = 77
    var sw_key = create_tls_key(null_value())
    sw_key.set(ptr_at(cell_addr(sentinel)))

    var slots = stack_allocation[2, BytePtr]()
    if ms_stack_alloc(STACK_BYTES, slots, slots + 1) != 0:
        # No synthetic-stack backend on this host/platform: RECORDED skip.
        skipped += 1
        skip_row(
            "S2.7 tls-ctx-switch-retains-value",
            "spike synthetic-stack backend unavailable (ms_stack_alloc)",
        )
    else:
        var cont_ok = True
        var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int64]()
        var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int64]()
        var main_ctx = main_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()
        var sf = SwitchFrame()
        sf.self_ctx = alt_ctx
        sf.back_ctx = main_ctx
        var sfp = UnsafePointer[SwitchFrame, MutAnyOrigin](to=sf).bitcast[Byte]()
        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["s27_conf_switch_alt"](), sfp)
        # Enter ALT; it yields straight back: one full suspend/resume cycle.
        ms_ctx_switch(main_ctx, alt_ctx)
        cont_ok = cont_ok and (addr_of(sw_key.get()) == cell_addr(sentinel))
        ms_stack_free(slots[])
        if not check("S2.7 tls-ctx-switch-retains-value", cont_ok):
            failed += 1

    # ---- verdict --------------------------------------------------------------------
    print("")
    print("SKIPPED (recorded): " + String(skipped))
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("s2-conformance-tls: " + String(failed) + " case(s) failed")
    print("RESULT: all green")
