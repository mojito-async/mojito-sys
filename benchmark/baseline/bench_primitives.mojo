"""
Mojito-sys M1.1 (#122) — pre-migration performance baseline for the §17
primitives that have no dedicated benchmark elsewhere in this tree:
FFI no-op crossing, page-size query, VM reserve/release, VM commit/
decommit, thread create/join, TLS get/set, monotonic clock read and
native event wait/wake.

The other four §17 rows (context switch, poller add/remove, poller wake,
socket loopback round trip) already have real benches committed —
benchmark/ctx/bench_switch.mojo and benchmark/io/{poller,socket_loopback}_
bench.mojo — and this file does not duplicate them; MOJO_MIGRATION_
BASELINE.md pulls their numbers in directly from a real run instead.

Methodology (matching benchmark/io/poller_bench.mojo, spec §38.12):
warmup rounds precede every measurement; a duration floor AND an
iteration floor keep micro-runs from being reported; all timing is
wall-clock monotonic ns via mojito_sys.time.monotonic. Each measurement
owns its own small helper function and its own handles — the b2 1.0.0b2
JIT is fragile when one frame carries many @extern calls and long loops,
so heavy measurements stay isolated the same way the poller bench does.

This is a ONE-TIME pre-migration snapshot (the Clang implementation as it
stands, which stays the oracle through Clang retirement per epic #121),
not an ongoing regression gate: it has no baselines.tsv / gate.sh pair the
way benchmark/ctx and benchmark/io do, because there is nothing yet to
regress against — the Mojo replacements this baseline exists to compare
against later don't exist until Phase 2. Its job is only to make sure the
first number recorded for each row is real.

Output contract: every row prints
    METRIC\t<metric_id>\t<VALUE>|SKIP\t<detail>
matching benchmark/io/poller_bench.mojo's own contract, so the same
run.sh-style parsing works unchanged.

Run (from repo root):
  mojo run -I . -Xlinker libmojito_sys.dylib benchmark/baseline/bench_primitives.mojo
"""

from std.memory import UnsafePointer, stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

from mojito_sys.memory.page import page_size
from mojito_sys.memory.virtual_memory import VirtualMemory
from mojito_sys.sync.event import NativeEvent
import mojito_sys.sync.externs as _sync_externs
from mojito_sys.thread.thread import (
    CThreadEntry,
    UserdataPtr,
    no_name,
    spawn_native_thread,
)
from mojito_sys.thread.tls import NativeTlsKey, TlsDtorPtr, TlsValuePtr
from mojito_sys.time.monotonic import MonotonicInstant, mjs_clock_now, monotonic_now

# ---- fixture libc plumbing (adds no mojito-sys ABI; matches the pattern
# already used by benchmark/io/poller_bench.mojo for pipe/usleep/etc.) ---
@extern("mjs_abi_version")
def mjs_abi_version() abi("C") -> Int32:
    ...


@extern("usleep")
def _usleep(useconds: UInt32) abi("C") -> Int32:
    ...


comptime WARMUP = 200
comptime MIN_ITERS = 20
comptime FLOOR_NS = 200000000  # 0.2 s floor, matching poller_bench.mojo


def emit(mid: String, value: Int, detail: String):
    print("METRIC\t" + mid + "\t" + String(value) + "\t" + detail)


def emit_skip(mid: String, reason: String):
    print("METRIC\t" + mid + "\tSKIP\t" + reason)


def _zero_int() -> Int:
    # b2 rejects `unsafe_from_address=0` literals (see
    # mojito_sys/thread/thread.mojo's _null_name()); the zero must travel
    # through a runtime local first.
    var zero = 0
    return zero


# ======================================================================
# 1. FFI no-op crossing — mjs_abi_version() is the cheapest possible
#    Mojo -> C call: it returns a compile-time constant with zero
#    C-side work, so its cost is (as close as this repo can get to) the
#    pure Mojo->C extern-call crossing overhead itself.
# ======================================================================
def measure_ffi_noop() raises:
    var warm = 0
    while warm < WARMUP:
        _ = mjs_abi_version()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 200000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var inner = 0
        while inner < 100:
            _ = mjs_abi_version()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    var calls = loops * 100
    emit(
        "ffi_noop.ops_per_sec",
        calls * 1000000000 // Int(el) if el > 0 else 0,
        "calls=" + String(calls),
    )


# ======================================================================
# 2. page-size query — mjs_page_size() via page_size().
# ======================================================================
def measure_page_size() raises:
    var warm = 0
    while warm < WARMUP:
        _ = page_size()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 200000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var inner = 0
        while inner < 100:
            _ = page_size()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    var calls = loops * 100
    emit(
        "page_size.ops_per_sec",
        calls * 1000000000 // Int(el) if el > 0 else 0,
        "calls=" + String(calls),
    )


# ======================================================================
# 3. VM reserve/release — VirtualMemory.reserve(bytes) + .release().
#    Each cycle is one mmap + one munmap syscall pair; a small N loop.
# ======================================================================
def measure_vm_reserve_release() raises:
    comptime RESERVE_BYTES = 1 << 20  # 1 MiB
    var warm = 0
    while warm < 50:
        var vm = VirtualMemory.reserve(RESERVE_BYTES)
        _ = vm.release()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 20000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var vm = VirtualMemory.reserve(RESERVE_BYTES)
        _ = vm.release()
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    emit(
        "vm_reserve_release.ops_per_sec",
        loops * 1000000000 // Int(el) if el > 0 else 0,
        "cycles=" + String(loops),
    )


# ======================================================================
# 4. VM commit/decommit — on a pre-reserved region, repeated commit then
#    decommit of the same page-sized sub-range.
# ======================================================================
def measure_vm_commit_decommit() raises:
    comptime RESERVE_BYTES = 1 << 20  # 1 MiB
    var ps = page_size()
    var vm = VirtualMemory.reserve(RESERVE_BYTES)
    var warm = 0
    while warm < 50:
        vm.commit(0, ps)
        vm.decommit(0, ps)
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 20000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        vm.commit(0, ps)
        vm.decommit(0, ps)
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    _ = vm.release()
    emit(
        "vm_commit_decommit.ops_per_sec",
        loops * 1000000000 // Int(el) if el > 0 else 0,
        "cycles=" + String(loops),
    )


# ======================================================================
# 5. thread create/join — a REAL pthread per cycle (spawn_native_thread +
#    join). Small N: this is orders of magnitude more expensive than any
#    other row here, and that expense IS the number of interest.
# ======================================================================
@export("mjs_bench_thread_noop_entry")
def _thread_noop_entry(ud: UserdataPtr) abi("C") -> Int64:
    return 0


def _thread_entry_pointer() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _mjs_bench_thread_noop_entry@PAGE\n"
        "add ${0:x}, ${0:x}, _mjs_bench_thread_noop_entry@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


def measure_thread_create_join() raises:
    var entry = _thread_entry_pointer()
    var ud = UserdataPtr(unsafe_from_address=_zero_int())
    var warm = 0
    while warm < 20:
        var t = spawn_native_thread(entry, ud, 0, no_name())
        _ = t.join()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    var cap = 2000
    while loops < cap:
        var t = spawn_native_thread(entry, ud, 0, no_name())
        _ = t.join()
        loops += 1
        now = monotonic_now().ticks
        if loops >= MIN_ITERS and now - start >= UInt64(FLOOR_NS):
            break
    var el = now - start
    emit(
        "thread_create_join.ops_per_sec",
        loops * 1000000000 // Int(el) if el > 0 else 0,
        "cycles=" + String(loops),
    )


# ======================================================================
# 6. TLS get/set — NativeTlsKey.create()/.set()/.get(); the get() path is
#    the one the header explicitly names SYS-4 (must-not-allocate).
# ======================================================================
def measure_tls_get_set() raises:
    var zero = _zero_int()
    var key = NativeTlsKey.create(TlsDtorPtr(unsafe_from_address=zero))
    var value = TlsValuePtr(unsafe_from_address=Int(0x1234))
    key.set(value)

    var warm = 0
    while warm < WARMUP:
        _ = key.get()
        key.set(value)
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 200000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var inner = 0
        while inner < 100:
            _ = key.get()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    var calls = loops * 100
    emit(
        "tls_get.ops_per_sec",
        calls * 1000000000 // Int(el) if el > 0 else 0,
        "calls=" + String(calls),
    )
    var mut_key = key
    mut_key.destroy()


# ======================================================================
# 7. monotonic clock read — MonotonicInstant.now() / mjs_clock_now().
# ======================================================================
def measure_clock_read() raises:
    var warm = 0
    while warm < WARMUP:
        _ = MonotonicInstant.now()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 200000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var inner = 0
        while inner < 100:
            _ = MonotonicInstant.now()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    var calls = loops * 100
    emit(
        "clock_read.ops_per_sec",
        calls * 1000000000 // Int(el) if el > 0 else 0,
        "calls=" + String(calls),
    )


# ======================================================================
# 8a. native event wait/wake — uncontended fast path: signal() then
#     wait() on the SAME thread, so wait() never actually blocks (the
#     token is already pending) and the number reflects the primitive's
#     own overhead rather than a scheduler round trip.
# ======================================================================
def measure_event_signal_wait() raises:
    var e = NativeEvent.create()
    var warm = 0
    while warm < WARMUP:
        e.signal()
        e.wait()
        warm += 1
    var loops = 0
    var start = monotonic_now().ticks
    var now = start
    while loops < 200000 and (loops < MIN_ITERS or now - start < UInt64(FLOOR_NS)):
        var inner = 0
        while inner < 100:
            e.signal()
            e.wait()
            inner += 1
        loops += 1
        if loops >= MIN_ITERS:
            now = monotonic_now().ticks
            if now - start >= UInt64(FLOOR_NS):
                break
    var el = now - start
    var calls = loops * 100
    emit(
        "event_signal_wait.ops_per_sec",
        calls * 1000000000 // Int(el) if el > 0 else 0,
        "calls=" + String(calls),
    )
    e.destroy()


# ======================================================================
# 8b. native event wait/wake — cross-thread wake latency: one worker
#     parks in wait(None-equivalent, i.e. plain wait()), the main thread
#     signals it after a short delay, and the timestamp between signal()
#     and the worker's wake is measured. Mirrors
#     benchmark/io/poller_bench.mojo's measure_wake_latency() exactly.
# ======================================================================
@export("mjs_bench_event_wait_entry")
def _event_wait_entry(ud: UserdataPtr) abi("C") -> Int64:
    # Cells (Int64, MutAnyOrigin): [0]=event handle, [1]=started, [2]=woke_at_ns.
    # Raw probe call, not the high-level NativeEvent wrapper: this runs on
    # a spawned thread inside an @export abi("C") entry, and every other
    # bench in this tree (e.g. benchmark/io/poller_bench.mojo's
    # _wake_wait_entry) keeps that frame down to raw extern/probe calls
    # only, matching the leaf-module discipline mojito_sys/thread/
    # externs.mojo documents (issue #49).
    var handle = ud[0]
    ud[1] = 1
    var rc = _sync_externs.probe_ev_wait(handle)
    if rc == 0:
        # Non-raising clock read (mjs_clock_now directly, not
        # monotonic_now()/MonotonicInstant.now()): this entry runs as an
        # @export abi("C") thread trampoline and must never raise into C
        # (the documented no-unwind rule), so it stays on the raw extern
        # here rather than the raising wrapper.
        var ns_cell = stack_allocation[1, UInt64]()
        var clk_rc = mjs_clock_now(ns_cell)
        ud[2] = Int64(ns_cell[0]) if clk_rc == 0 else Int64(-1)
    else:
        ud[2] = Int64(-1)
    return 0


def _event_entry_pointer() -> CThreadEntry:
    comptime asm_str = (
        "adrp ${0:x}, _mjs_bench_event_wait_entry@PAGE\n"
        "add ${0:x}, ${0:x}, _mjs_bench_event_wait_entry@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return CThreadEntry(unsafe_from_address=Int(addr))


def measure_event_wake_latency() raises:
    comptime SAMPLES = 16
    var entry = _event_entry_pointer()
    var samples = stack_allocation[SAMPLES, Int64]()
    var ok = True
    var s = 0
    while s < SAMPLES:
        var e = NativeEvent.create()
        var cells = stack_allocation[3, Int64]()
        cells[0] = Int64(e.handle)
        cells[1] = 0
        cells[2] = 0
        var ud = UserdataPtr(unsafe_from_address=Int(cells))
        var worker = spawn_native_thread(_event_entry_pointer(), ud, 0, no_name())
        # Bounded spin for BOTH phases (matching benchmark/io/poller_bench.mojo's
        # measure_wake_latency() exactly): an unbounded `while cells[1] == 0`
        # here can never return if the worker never reaches the entry body
        # (e.g. a bad function-pointer resolution), and a benchmark that can
        # hang forever is worse than one that reports a clean SKIP.
        var spin_t0 = monotonic_now().ticks
        while cells[1] == 0 and (monotonic_now().ticks - spin_t0) < UInt64(3000000000):
            _ = _usleep(UInt32(50))
        var signal_at = monotonic_now().ticks
        e.signal()
        while cells[2] == 0 and (monotonic_now().ticks - signal_at) < UInt64(3000000000):
            _ = _usleep(UInt32(50))
        _ = worker.join()
        if cells[1] == 0 or cells[2] <= 0:
            ok = False
        else:
            var dt = UInt64(cells[2]) - signal_at
            samples[s] = Int64(dt)
        e.destroy()
        s += 1
    if ok:
        # Simple insertion-sort median (SAMPLES is tiny), matching
        # benchmark/io/poller_bench.mojo's median_ns() helper shape.
        var i = 1
        while i < SAMPLES:
            var key = samples[i]
            var j = i - 1
            while j >= 0 and samples[j] > key:
                samples[j + 1] = samples[j]
                j -= 1
            samples[j + 1] = key
            i += 1
        emit(
            "event_wake_latency_ns",
            Int(samples[SAMPLES // 2]),
            "n=" + String(SAMPLES),
        )
    else:
        emit_skip("event_wake_latency_ns", "wake did not return cleanly")


def main() raises:
    print("# mojito-sys M1.1 (#122) primitive baseline")
    print()
    print("## Environment")
    print("| item | value |")
    print("|---|---|")
    var host = String("darwin") if CompilationTarget().is_macos() else String("linux")
    print("| host |", host, "|")
    print()

    measure_ffi_noop()
    measure_page_size()
    measure_vm_reserve_release()
    measure_vm_commit_decommit()
    measure_thread_create_join()
    measure_tls_get_set()
    measure_clock_read()
    measure_event_signal_wait()
    measure_event_wake_latency()
    print()
    print("bench_primitives: complete")
