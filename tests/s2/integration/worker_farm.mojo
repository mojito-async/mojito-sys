# mojito-sys S2.9 — THE §41 EXIT-CRITERION integration test (issue #56).
#
# End-to-end proof of spec L2334-2338: DOWNSTREAM code builds a small worker
# farm using ONLY the public mojito-sys surface — no private runtime APIs, no
# module-level mutable globals:
#
#   1. spawn-farm           — N workers spawned via
#     mojito_sys.thread.thread.spawn_native_thread (the §11.1 wrapper);
#   2. worker-tls-binding   — every worker stores ITS OWN worker-pointer cell
#     in ONE shared NativeTlsKey (mojito_sys.thread.tls) and retrieves it;
#   3. switch-continuity    — every worker retrieves the SAME binding again
#     AFTER crossing a synthetic context switch (spike switch pair) ON ITS OWN
#     THREAD, proving TLS survives suspend/resume per-thread, concurrently
#     across the whole farm;
#   4. clean-join           — every worker joins cleanly with zero status via
#     NativeThread.join();
#   5. main-isolation       — main's own binding under the same key never
#     aliases any worker's (per-(key,thread) semantics) and survives a
#     main-side synthetic context switch too.
#
# First-consumer contract audit (spec L888-893, the reason this file exists):
#   - ZERO private runtime APIs: everything imported below is public mojito_sys
#     or the public mojito_spike test scaffold (context-switch pair);
#   - ZERO module-level mutable globals: results travel through per-worker
#     userdata cells; failure accounting is a main()-local counter.
#
# Straight-green justification (TDD): this is glue over already-merged,
# individually-conformed parts (S2.2 #49, S2.4 #51, spike pair) — there is no
# new implementation to make red; the red-first step applies only to new
# wrappers/C layers, none of which this lane adds.
#
# b2 notes (repo conventions):
#   - Worker entries are @export abi("C") and deliberately RAISE-FREE: the C
#     trampoline has no error channel. Errors surface as recorded rc cells
#     checked by main after join; main-side code uses the raising wrappers.
#   - Null pointers come from a RUNTIME zero (`unsafe_from_address=0` literal
#     is rejected); UnsafePointer is non-nullable, "unset" is the zero address.
#   - The worker SETS its binding through the public NativeTlsKey.set()
#     using the same try/except-into-result-cells shape proven in
#     tests/s2/conformance/tls/conformance.mojo tls_worker_entry: raises
#     NEVER cross the C boundary — a failed set lands as set_rc != 0 and is
#     checked by main after join. Both bind and retrieve now go through the
#     ONE public typed handle (§41 criterion: downstream code without
#     private-API spellings).
#
# Run via tests/s2/integration/run.sh (builds both dylibs first).
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
from mojito_sys.thread.thread import (
    NativeThread,
    no_name,
    spawn_native_thread,
)
from mojito_sys.thread.tls import (
    NativeTlsKey,
    TlsValuePtr,
)

comptime NUM_WORKERS = 4
comptime STACK_BYTES = 262144


# --- small b2-safe helpers ---------------------------------------------------

# Null construction centralization (b2 rejects comptime-zero literals).
def null_value() -> TlsValuePtr:
    var zero = 0
    return TlsValuePtr(unsafe_from_address=zero)


def byte_at(a: Int) -> BytePtr:
    return BytePtr(unsafe_from_address=a)


def ptr_at(a: Int) -> TlsValuePtr:
    return TlsValuePtr(unsafe_from_address=a)


def addr_of(p: TlsValuePtr) -> Int:
    return Int(p)


def cell_addr(p: UnsafePointer[Int, MutAnyOrigin]) -> Int:
    return Int(p)


# Prints the verdict row only; main() accumulates failures locally (b2
# forbids module-level mutable globals).
def check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


# --- exported code addresses (spike entry_pointer pattern) -------------------

# Per-worker argument + result cell. Written by MAIN before spawn; the worker
# records its results here; join() is the synchronization point that makes
# them visible to main (no locks, no globals — first-consumer contract).
struct WorkerArg:
    var key_id: UInt          # shared NativeTlsKey id (minted by main)
    var payload_addr: Int     # THIS worker's pointer cell (its "worker pointer")
    var set_rc: Int32         # typed key.set() result cell (0 = bound)
    var got_before: Int       # retrieved binding address BEFORE the switch
    var switch_rc: Int32      # ms_stack_alloc rc for the worker-local pair
    var got_after: Int        # retrieved binding address AFTER the switch

    def __init__(out self):
        self.key_id = 0
        self.payload_addr = 0
        self.set_rc = -1
        self.got_before = 0
        self.switch_rc = -1
        self.got_after = 0


# Synthetic context-switch alternate: yields straight back, so the entering
# thread (here: each WORKER's pthread) crosses ONE suspend/resume cycle.
struct SwitchFrame:
    var self_ctx: BytePtr
    var back_ctx: BytePtr

    def __init__(out self):
        self.self_ctx = byte_at(0)
        self.back_ctx = byte_at(0)


@export("s29_switch_alt")
def switch_alt(ud: BytePtr) abi("C"):
    var fp = ud.bitcast[SwitchFrame]()
    ms_ctx_switch(fp[].self_ctx, fp[].back_ctx)


# Worker body (§41 shape): bind THIS thread's worker-pointer cell under the
# shared key, read it back, cross a worker-local synthetic context switch,
# read it back AGAIN, record everything. Raise-free (see header b2 notes).
@export("s29_worker_entry")
def worker_entry(ud: BytePtr) abi("C"):
    var wa = ud.bitcast[WorkerArg]()
    # Bind through the PUBLIC typed handle: try/except-into-result-cells
    # (proven conformance pattern) keeps the C entry raise-free.
    var k = NativeTlsKey(wa[].key_id)
    wa[].set_rc = -1
    try:
        k.set(ptr_at(wa[].payload_addr))
        wa[].set_rc = 0
    except e:
        _ = e  # recorded as set_rc != 0
    # Retrieve through the TYPED handle adopted from the shared key id —
    # the public downstream pattern (get() is non-raising).
    wa[].got_before = addr_of(k.get())
    # Worker-local synthetic context switch on THIS OS thread.
    var slots = stack_allocation[2, BytePtr]()
    wa[].switch_rc = ms_stack_alloc(STACK_BYTES, slots, slots + 1)
    if wa[].switch_rc == 0:
        var self_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
        var main_ctx = self_buf.bitcast[Byte]()
        var alt_ctx = alt_buf.bitcast[Byte]()
        var sf = SwitchFrame()
        sf.self_ctx = alt_ctx
        sf.back_ctx = main_ctx
        var sfp = UnsafePointer[SwitchFrame, MutAnyOrigin](to=sf).bitcast[Byte]()
        ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["s29_switch_alt"](), sfp)
        # Enter ALT; it yields straight back: one full suspend/resume cycle.
        ms_ctx_switch(main_ctx, alt_ctx)
        wa[].got_after = addr_of(k.get())
        ms_stack_free(slots[])


# --- conformance -------------------------------------------------------------

def main() raises:
    var failed = 0

    # One shared key for the whole farm, minted through the public factory.
    var key = NativeTlsKey.create(null_value())

    # ---- 5 (early setup). main binds its own sentinel under the same key ---
    var sentinel = stack_allocation[1, Int]()
    sentinel[] = 41000
    key.set(ptr_at(cell_addr(sentinel)))

    # ---- 1. spawn-farm: N workers via mojito_sys.thread --------------------
    var was = stack_allocation[NUM_WORKERS, WorkerArg]()
    var payloads = stack_allocation[NUM_WORKERS, Int]()
    var i = 0
    while i < NUM_WORKERS:
        payloads[i] = 1000 + i
        was[i].key_id = key.key
        was[i].payload_addr = cell_addr(payloads + i)
        i += 1

    var threads = stack_allocation[NUM_WORKERS, NativeThread]()
    var spawn_failures = 0
    i = 0
    while i < NUM_WORKERS:
        var ud = UnsafePointer[WorkerArg, MutAnyOrigin](to=was[i]).bitcast[Int64]()
        try:
            var t = spawn_native_thread(
                entry_pointer["s29_worker_entry"](),
                ud,
                0,
                no_name(),
            )
            threads[i] = t^
        except e:
            spawn_failures += 1
            print("spawn worker " + String(i) + " raised: " + String(e))
        i += 1

    if not check(
        "S2.9 spawn-farm-" + String(NUM_WORKERS) + "-workers",
        spawn_failures == 0,
    ):
        failed += 1

    # ---- 2/3/4. join cleanly; verify bindings incl. across the switch ------
    var join_ok = True
    var binding_ok = True
    var switch_ok = True
    i = 0
    while i < NUM_WORKERS:
        var st = threads[i].join()
        if st != 0:
            join_ok = False
        if was[i].set_rc != 0 or was[i].got_before != was[i].payload_addr:
            binding_ok = False
        if (
            was[i].switch_rc != 0
            or was[i].got_after != was[i].payload_addr
            or was[i].got_before != was[i].got_after
        ):
            switch_ok = False
        i += 1

    if not check("S2.9 clean-join-zero-status", join_ok):
        failed += 1
    if not check("S2.9 worker-tls-binding-per-thread", binding_ok):
        failed += 1
    if not check("S2.9 binding-survives-synthetic-switch", switch_ok):
        failed += 1

    # ---- 5. main isolation + main-side switch continuity -------------------
    var iso_ok = addr_of(key.get()) == cell_addr(sentinel)
    if iso_ok:
        var slots = stack_allocation[2, BytePtr]()
        if ms_stack_alloc(STACK_BYTES, slots, slots + 1) == 0:
            var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
            var alt_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
            var main_ctx = main_buf.bitcast[Byte]()
            var alt_ctx = alt_buf.bitcast[Byte]()
            var sf = SwitchFrame()
            sf.self_ctx = alt_ctx
            sf.back_ctx = main_ctx
            var sfp = UnsafePointer[SwitchFrame, MutAnyOrigin](to=sf).bitcast[Byte]()
            ms_ctx_make(alt_ctx, (slots + 1)[], entry_pointer["s29_switch_alt"](), sfp)
            ms_ctx_switch(main_ctx, alt_ctx)
            iso_ok = addr_of(key.get()) == cell_addr(sentinel)
            ms_stack_free(slots[])
        else:
            iso_ok = False
    if not check("S2.9 main-isolation-and-own-switch", iso_ok):
        failed += 1

    # Teardown: retire the farm's key (no destructor registered).
    key.destroy()

    print("")
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("s2-integration worker_farm: " + String(failed) + " check(s) failed")
    print("RESULT: all green")
