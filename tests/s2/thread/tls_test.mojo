# mojito-sys S2.4 — NativeTlsKey conformance (issue #51, spec §12 / §38.5).
#
# Drives the §12 TLS surface (mojito_sys.thread.tls NativeTlsKey bound to the
# frozen mjs_tls_* C ABI) through the §38.5 TLS check list:
#
#   1. create-distinct      — create_tls_key mints distinct nonzero keys;
#   2. set-get-roundtrip    — bind/unbind round-trip and overwrite;
#   3. two-key-isolation    — two keys on one thread never alias;
#   4. per-thread-isolation — worker thread binds its OWN value under the
#     same key; neither side observes the other's binding after join, and
#     the registered destructor fired EXACTLY ONCE for the worker binding;
#   5. invalid-key          — never-minted key: get() is null, set/destroy
#     raise the decoded -EINVAL;
#   6. use-after-destroy    — destroy consumes; a stale alias raises
#     decoded -EINVAL on set, get() is null, double destroy raises;
#   7. switch-continuity    — SAME value retained across a synthetic context
#     switch (spike switch pair, spec L1851/L1860).
#
# Thread spawning: the NativeThread-driven isolation/reuse/destructor legs
# now live in tests/s2/conformance/tls/conformance.mojo (issue #54); this
# suite keeps its raw-pthread worker as an independent C-ABI cross-check.
#
# b2 notes (repo conventions):
#   - Null pointers come from a RUNTIME zero (`unsafe_from_address=0` literal
#     is rejected in 1.0.0b2); UnsafePointer is non-nullable, so "unset" is
#     the zero address, checked via Int(ptr) == 0.
#   - Exactly ONE raise funnel: wrappers raise through raise_errno; this
#     suite catches and checks the decoded message. All other diagnostics go
#     to stdout; failures accumulate in `failed`.
#   - No module-level mutable globals anywhere (first-consumer contract,
#     spec L888-893): destructor accounting counts INTO THE BOUND PAYLOAD
#     cell, worker results travel through a userdata struct.
#
# Run via tests/s2/thread/run.sh (builds both dylibs first).

from std.memory import stack_allocation

from mojito_spike import (
    BytePtr,
    MS_CTX_SIZE,
    entry_pointer,
    ms_ctx_make,
    ms_ctx_switch,
    ms_stack_alloc,
    ms_stack_free,
)
from mojito_sys.thread.tls import (
    NativeTlsKey,
    TlsValuePtr,
    create_tls_key,
    mjs_tls_get,
    mjs_tls_set,
)

comptime STACK_BYTES = 262144


# --- small b2-safe helpers --------------------------------------------------

# Null construction centralization (b2 rejects comptime-zero literals).
def null_value() -> TlsValuePtr:
    var zero = 0
    return TlsValuePtr(unsafe_from_address=zero)


def null_byte() -> BytePtr:
    var zero = 0
    return BytePtr(unsafe_from_address=zero)


def byte_at(a: Int) -> BytePtr:
    return BytePtr(unsafe_from_address=a)


def addr_of(p: TlsValuePtr) -> Int:
    return Int(p)


# Address of a test-local Int payload cell (typed pointer form).
def cell_addr(p: UnsafePointer[Int, MutAnyOrigin]) -> Int:
    return Int(p)


def ptr_at(a: Int) -> TlsValuePtr:
    return TlsValuePtr(unsafe_from_address=a)


# True iff `msg` carries the decoded errno name (raise_errno renders
# "... POSIX errno 22 (EINVAL)").
def mentions_einval(msg: String) -> Bool:
    return msg.find("EINVAL") != -1


# --- exported code addresses (spike entry_pointer pattern) ------------------

# Destructor payload protocol: every bound value points at an Int cell; the
# destructor increments the cell it receives. Accounting lives in the payload,
# NOT in a global (first-consumer contract, spec L888-893).
@export("s24_tls_counting_dtor")
def counting_dtor(value: BytePtr) abi("C"):
    var cell = value.bitcast[Int]()
    cell[] = cell[] + 1


struct WorkerArg:
    # Written by MAIN before spawn, read by WORKER; results written by
    # WORKER, read by MAIN after join (join is the synchronization point).
    var key_id: UInt
    var bind_addr: Int
    var set_rc: Int32
    var got_addr: Int

    def __init__(out self):
        self.key_id = 0
        self.bind_addr = 0
        self.set_rc = -1
        self.got_addr = 0


# Worker body: bind THIS thread's value under the shared key, read it back,
# record both. Deliberately allocation-free and raise-free — raw ABI calls +
# plain memory writes only (mirrors the C smoke worker).
# The NativeThread.spawn variant of this worker lives in
# tests/s2/conformance/tls/conformance.mojo (issue #54).
@export("s24_tls_worker_entry")
def tls_worker_entry(ud: BytePtr) abi("C"):
    var wa = ud.bitcast[WorkerArg]()
    wa[].set_rc = mjs_tls_set(wa[].key_id, ptr_at(wa[].bind_addr))
    wa[].got_addr = addr_of(mjs_tls_get(wa[].key_id))


# Synthetic context switch pair (spike pattern): the alternate context yields
# straight back, so main crosses ONE suspend/resume cycle.
struct SwitchFrame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr

    def __init__(out self):
        self.self_ctx = null_byte()
        self.back_ctx = null_byte()


@export("s24_switch_alt")
def switch_alt(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[SwitchFrame]()
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


# Raw pthread spawn plumbing (independent C-ABI cross-check; the
# mojito_sys.thread-driven variant is tests/s2/conformance/tls, issue #54):
# pthread_t travels as one word-sized slot; attr/retval may be NULL.
@extern("pthread_create")
def _pthread_create(
    thread: UnsafePointer[UInt, MutAnyOrigin],
    attr: BytePtr,
    start_routine: BytePtr,
    arg: BytePtr,
) abi("C") -> Int32:
    ...


@extern("pthread_join")
def _pthread_join(thread: BytePtr, retval: BytePtr) abi("C") -> Int32:
    ...


# Spawn the arg-carrying worker and join it; returns the first nonzero rc of
# pthread_create / pthread_join (0 = clean round trip).
def spawn_worker(arg: UnsafePointer[WorkerArg, MutAnyOrigin]) -> Int32:
    var tid_slot = stack_allocation[1, UInt]()
    var rc = _pthread_create(
        tid_slot,
        null_byte(),
        entry_pointer["s24_tls_worker_entry"](),
        arg.bitcast[Byte](),
    )
    if rc != 0:
        return rc
    return _pthread_join(byte_at(Int(tid_slot[])), null_byte())


# --- conformance ------------------------------------------------------------

def main() raises:
    var failed = 0

    # ---- 1. create: distinct nonzero keys ---------------------------------
    var k1 = create_tls_key(null_value())
    var k2 = create_tls_key(null_value())
    var distinct_ok = (
        (k1.key != 0) and (k2.key != 0) and (k1.key != k2.key)
    )
    if distinct_ok:
        print("S2.4 create-distinct-nonzero:            PASS")
    else:
        print(
            "S2.4 create-distinct-nonzero:            FAIL ("
            + String(k1.key)
            + ", "
            + String(k2.key)
            + ")"
        )
        failed += 1

    # ---- 2. set/get round-trip + overwrite --------------------------------
    var payload_a = stack_allocation[1, Int]()
    var payload_b = stack_allocation[1, Int]()
    payload_a[] = 11
    payload_b[] = 22
    var rt_ok = True
    rt_ok = rt_ok and (addr_of(k2.get()) == 0)  # unset -> null
    k2.set(ptr_at(cell_addr(payload_a)))
    rt_ok = rt_ok and (addr_of(k2.get()) == cell_addr(payload_a))
    k2.set(ptr_at(cell_addr(payload_b)))  # overwrite
    rt_ok = rt_ok and (addr_of(k2.get()) == cell_addr(payload_b))
    if rt_ok:
        print("S2.4 set-get-roundtrip-overwrite:        PASS")
    else:
        print("S2.4 set-get-roundtrip-overwrite:        FAIL")
        failed += 1

    # ---- 3. two-key isolation on ONE thread -------------------------------
    var k3 = create_tls_key(null_value())
    k2.set(ptr_at(cell_addr(payload_a)))
    k3.set(ptr_at(cell_addr(payload_b)))
    var iso2_ok = (addr_of(k2.get()) == cell_addr(payload_a)) and (
        addr_of(k3.get()) == cell_addr(payload_b)
    )
    if iso2_ok:
        print("S2.4 two-key-isolation-same-thread:      PASS")
    else:
        print("S2.4 two-key-isolation-same-thread:      FAIL")
        failed += 1

    # ---- 4. per-thread isolation + destructor-once over a spawned thread --
    # Shared counting-destructor key; each thread binds its OWN payload cell.
    var worker_payload = stack_allocation[1, Int]()
    worker_payload[] = 0
    var main_payload = stack_allocation[1, Int]()
    main_payload[] = 33
    var dtor_key = create_tls_key(
        entry_pointer["s24_tls_counting_dtor"]().bitcast[NoneType]()
    )
    dtor_key.set(ptr_at(cell_addr(main_payload)))

    var wa = WorkerArg()
    wa.key_id = dtor_key.key
    wa.bind_addr = cell_addr(worker_payload)

    var spawn_rc = spawn_worker(UnsafePointer[WorkerArg, MutAnyOrigin](to=wa))

    var thread_ok = spawn_rc == 0
    thread_ok = thread_ok and (wa.set_rc == 0)
    thread_ok = thread_ok and (wa.got_addr == cell_addr(worker_payload))
    # Isolation: main's binding survived the worker's set on the same key id.
    thread_ok = thread_ok and (
        addr_of(dtor_key.get()) == cell_addr(main_payload)
    )
    # Destructor fired EXACTLY ONCE at worker exit (join is the sync point).
    thread_ok = thread_ok and (worker_payload[] == 1)
    if thread_ok:
        print("S2.4 per-thread-isolation+dtor-once:     PASS")
    else:
        print(
            "S2.4 per-thread-isolation+dtor-once:     FAIL (spawn="
            + String(spawn_rc)
            + " set_rc="
            + String(wa.set_rc)
            + " got="
            + String(wa.got_addr)
            + " dtor_count="
            + String(worker_payload[])
            + ")"
        )
        failed += 1

    # ---- 5. never-minted key: deterministic -EINVAL -----------------------
    var bogus = NativeTlsKey(UInt(987654321))
    var bogus_ok = addr_of(bogus.get()) == 0
    var bogus_set_raised = False
    try:
        bogus.set(ptr_at(cell_addr(payload_a)))
    except e:
        bogus_set_raised = mentions_einval(String(e))
    bogus_ok = bogus_ok and bogus_set_raised
    var bogus_destroy_raised = False
    try:
        bogus.destroy()
    except e:
        bogus_destroy_raised = mentions_einval(String(e))
    bogus_ok = bogus_ok and bogus_destroy_raised
    if bogus_ok:
        print("S2.4 invalid-key-einval:                 PASS")
    else:
        print(
            "S2.4 invalid-key-einval:                 FAIL (set_raised="
            + String(bogus_set_raised)
            + " destroy_raised="
            + String(bogus_destroy_raised)
            + ")"
        )
        failed += 1

    # ---- 6. destroy consumes; use-after-destroy is decoded -EINVAL -------
    var doomed = create_tls_key(null_value())
    var stale = doomed  # second handle (alias) to the same underlying key
    var uad_ok = True
    doomed.destroy()  # consumes `doomed`; the key id is dead at the C layer
    # set through a stale alias AFTER destroy: decoded -EINVAL raise.
    var stale_set_raised = False
    try:
        stale.set(ptr_at(cell_addr(payload_a)))
    except e:
        stale_set_raised = mentions_einval(String(e))
    uad_ok = uad_ok and stale_set_raised
    # get through the stale alias: documented null (never aliases).
    uad_ok = uad_ok and (addr_of(stale.get()) == 0)
    # double destroy via the remaining handle: decoded -EINVAL raise.
    var dbl_raised = False
    try:
        stale.destroy()
    except e:
        dbl_raised = mentions_einval(String(e))
    uad_ok = uad_ok and dbl_raised
    if uad_ok:
        print("S2.4 use-after-destroy-einval:           PASS")
    else:
        print(
            "S2.4 use-after-destroy-einval:           FAIL (set="
            + String(stale_set_raised)
            + " dbl="
            + String(dbl_raised)
            + ")"
        )
        failed += 1

    # ---- 7. SAME value across a synthetic context switch ------------------
    var cont_ok = True
    var sentinel = stack_allocation[1, Int]()
    sentinel[] = 77
    var sw_key = create_tls_key(null_value())
    sw_key.set(ptr_at(cell_addr(sentinel)))

    var slots = stack_allocation[2, BytePtr]()
    if ms_stack_alloc(STACK_BYTES, slots, slots + 1) != 0:
        cont_ok = False
    else:
        var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var main_ctx = main_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()
        var sf = SwitchFrame()
        sf.self_ctx = alt_ctx
        sf.back_ctx = main_ctx
        var sfp = UnsafePointer[SwitchFrame, MutAnyOrigin](to=sf).bitcast[Byte]()
        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["s24_switch_alt"](), sfp)
        # Enter ALT; it yields straight back: one full suspend/resume cycle.
        ms_ctx_switch(main_ctx, alt_ctx)
        cont_ok = cont_ok and (addr_of(sw_key.get()) == cell_addr(sentinel))
        ms_stack_free(slots[])
    if cont_ok:
        print("S2.4 switch-continuity-same-value:       PASS")
    else:
        print("S2.4 switch-continuity-same-value:       FAIL")
        failed += 1

    print("")
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("s2-tls-mojo: " + String(failed) + " check(s) failed")
    print("RESULT: all green")
