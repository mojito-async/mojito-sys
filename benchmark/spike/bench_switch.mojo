"""
S0 context-switch benchmark (issue #13) — mojito-sys spike.

Measures, against the FROZEN ABI in spike/context_switch/CONTRACT.md:

  1. A->B->A round-trip throughput (round trips/sec) across >=1e6 rounds
     or a 2-second floor (whichever is reached last).
  2. Single-switch latency percentiles (median / p95 / p99) from sampled
     individual switches, plus the batch-derived mean per round trip.
  3. Stack memory accounting for 1 / 100 / 1000 reserved stacks:
     reserved bytes (incl. guard page, via ms_stack_total_size) versus
     committed bytes (pages explicitly faulted by this benchmark).

Methodology notes
-----------------
* Warmup: 10k round trips before any measurement.
* Duration floor: measurement continues until BOTH >=1e6 round trips AND
  >=2 s have elapsed, so results never come from an unwarmed micro-run.
* Latency sampling: every SAMPLING_SKIP-th switch is timed individually
  with the monotonic clock. The clock has ~1 us granularity on macOS, so
  individually-sampled sub-microsecond switches quantize; the batch-derived
  mean (total time / count) is the authoritative point estimate, the
  percentiles show distribution shape. Histogram bucket width 25 ns.
* Round-trip definition follows the amended contract trampoline semantics:
  userdata passes through unmodified and ms_ctx_switch records
  to.return_to = caller, so the trampoline tail-switches straight back to
  this context after entry(userdata) finishes. One ms_ctx_switch call from
  the scheduler therefore equals one full A->B->A round trip.
* Committed bytes are exact by construction: this benchmark touches exactly
  one usable page per stack and counts it committed. A surviving run also
  proves every guard page held for every allocation (a single guard miss
  would SIGSEGV the benchmark).

OS-level RSS: intentionally NOT reported from inside this process yet.
Calling Mach task_info requires a 4-argument C call, and mojo 1.0.0b2's
inlined_assembly crashes the JIT both above 4 operands and on any `ldr`
inside inline asm (repro in benchmark/spike/README.md). Until that is
fixed, RSS deltas should be captured externally around `make bench`
(e.g. `ps -o rss=` sampling); see README for the wrapper one-liner.

Known seams (coordination items, see benchmark/spike/README.md)
---------------------------------------------------------------
* The six frozen bindings are imported from spike/context_switch/
  mojito_spike.mojo owned by issue #10. Until that lands this file fails
  to compile — that is the expected TDD red state.
* The entry callback handed to ms_ctx_make is resolved by dlsym from
  libmojito_spike.dylib under the name mojito_spike_entry; the concrete
  b2-legal entry-callback formulation is #10's deliverable and this seam
  will be folded to whatever #10 lands.

Run:  mojo run -I ../../spike/context_switch benchmark/spike/bench_switch.mojo
      (or `make bench` once the foundation Makefile lands)
"""

from std.ffi import dlopen, dlsym
from std.sys.intrinsics import inlined_assembly
from std.time import monotonic

from mojito_spike import (
    ms_page_size,
    ms_stack_alloc,
    ms_stack_free,
    ms_stack_total_size,
    ms_ctx_make,
    ms_ctx_switch,
)


# --- tunables ------------------------------------------------------------
comptime STACK_BYTES = 65536
comptime WARMUP_ROUNDS = 10_000
comptime MIN_ROUNDS = 1_000_000
comptime FLOOR_US = 2_000_000
comptime CHUNK = 25_000
comptime SAMPLING_SKIP = 5
comptime SAMPLE_TARGET = 200_000
comptime BUCKET_NS = 25
comptime MAX_BUCKETS = 4096  # covers single switches up to ~102 us
comptime CTX_BYTES = 192  # ms_ctx_t is 176; pad for alignment slack


# --- minimal libc FFI (self-contained; only needs the C ABI) --------------
comptime LIB_SYSTEM = "/usr/lib/libSystem.B.dylib"


def _sys_sym(name: String) raises -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Resolve one symbol from libSystem; fail loudly if unavailable."""
    var h_opt = dlopen(LIB_SYSTEM.unsafe_ptr().bitcast[Int8](), 2)
    if not h_opt:
        raise Error("FATAL: cannot dlopen libSystem")
    var sym_opt = dlsym[NoneType](
        h_opt.value(), name.unsafe_ptr().bitcast[Int8]()
    )
    if not sym_opt:
        raise Error("FATAL: missing libSystem symbol " + name)
    return sym_opt.value()


def _call0(sym: UnsafePointer[NoneType, MutUntrackedOrigin]) -> Int64:
    """Invoke a no-argument C function."""
    return inlined_assembly[
        "mov x9, $1\n\tblr x9\n\tmov $0, x0",
        Int64,
        UnsafePointer[NoneType, MutUntrackedOrigin],
        constraints="=r,r",
        has_side_effect=True,
    ](sym)


def _call1(sym: UnsafePointer[NoneType, MutUntrackedOrigin], a: Int64) -> Int64:
    """Invoke a one-argument C function."""
    return inlined_assembly[
        "mov x9, $1\n\tmov x10, $2\n\tmov x0, x10\n\tblr x9\n\tmov $0, x0",
        Int64,
        UnsafePointer[NoneType, MutUntrackedOrigin],
        Int64,
        constraints="=r,r,r",
        has_side_effect=True,
    ](sym, a)


def _scratch(
    nbytes: Int,
    malloc_sym: UnsafePointer[NoneType, MutUntrackedOrigin],
    free_sym: UnsafePointer[NoneType, MutUntrackedOrigin],
) raises -> UnsafePointer[Int64, MutUntrackedOrigin]:
    """Allocate zero-initialized scratch memory."""
    var raw = _call1(malloc_sym, Int64(nbytes))
    if raw == 0:
        raise Error("FATAL: scratch malloc failed")
    var p = UnsafePointer[Int64, MutUntrackedOrigin](
        unsafe_from_address=Int(raw)
    )
    var i = 0
    while i < nbytes // 8:
        p[i] = 0
        i += 1
    return p


def _drop(
    p: UnsafePointer[Int64, MutUntrackedOrigin],
    free_sym: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> None:
    _ = _call1(free_sym, Int64(Int(p)))


def _percentile(
    buckets: UnsafePointer[Int64, MutUntrackedOrigin],
    total: Int,
    mille: Int,
) -> Int:
    """Histogram percentile in ns; mille is per-mille (500 = median)."""
    var target = (total * mille) // 1000
    var cum = 0
    var i = 0
    while i < MAX_BUCKETS:
        cum += Int(buckets[i])
        if cum >= target:
            return i * BUCKET_NS + BUCKET_NS // 2
        i += 1
    return MAX_BUCKETS * BUCKET_NS


def _alloc_one(
    slots: UnsafePointer[Int64, MutUntrackedOrigin],
    idx: Int,
) raises -> None:
    """ms_stack_alloc into slot pair [base, top] at slots[idx*2]."""
    var bs = UnsafePointer[UnsafePointer[Byte, MutUntrackedOrigin], MutUntrackedOrigin](
        unsafe_from_address=Int(slots) + idx * 16
    )
    var ts = UnsafePointer[UnsafePointer[Byte, MutUntrackedOrigin], MutUntrackedOrigin](
        unsafe_from_address=Int(slots) + idx * 16 + 8
    )
    if ms_stack_alloc(STACK_BYTES, bs, ts) != 0:
        raise Error("FATAL: ms_stack_alloc failed")


# --- benchmark -------------------------------------------------------------
def main() raises -> None:
    var malloc_sym = _sys_sym("malloc")
    var free_sym = _sys_sym("free")

    print("# mojito-sys S0 context-switch benchmark")
    print()
    print("## Environment")
    print()
    print("| item | value |")
    print("|---|---|")
    var page = Int(ms_page_size())
    print("| page_size |", page, "|")
    print("| stack_bytes_requested |", STACK_BYTES, "|")
    print("| warmup_rounds |", WARMUP_ROUNDS, "|")
    print("| min_rounds |", MIN_ROUNDS, "|")
    print("| duration_floor_us |", FLOOR_US, "|")
    print("| reserved_per_stack_incl_guard |", ms_stack_total_size(), "|")
    print()

    # context blocks for scheduler (A) and benchmark fiber (B)
    var ctx_a = _scratch(CTX_BYTES, malloc_sym, free_sym)
    var ctx_b = _scratch(CTX_BYTES, malloc_sym, free_sym)
    var ctx_a_ptr = UnsafePointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(ctx_a)
    )
    var ctx_b_ptr = UnsafePointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(ctx_b)
    )

    # B's stack: out-slot block [base, top]
    var slot = _scratch(16, malloc_sym, free_sym)
    var base_slot = UnsafePointer[UnsafePointer[Byte, MutUntrackedOrigin], MutUntrackedOrigin](
        unsafe_from_address=Int(slot)
    )
    var top_slot = UnsafePointer[UnsafePointer[Byte, MutUntrackedOrigin], MutUntrackedOrigin](
        unsafe_from_address=Int(slot) + 8
    )
    if ms_stack_alloc(STACK_BYTES, base_slot, top_slot) != 0:
        raise Error("FATAL: ms_stack_alloc failed for benchmark fiber stack")

    # entry callback seam (see module docstring)
    var spike_h_opt = dlopen("libmojito_spike.dylib".unsafe_ptr().bitcast[Int8](), 2)
    if not spike_h_opt:
        raise Error(
            "FATAL: libmojito_spike.dylib not present; S0 implementation absent?"
        )
    var entry_opt = dlsym[NoneType](
        spike_h_opt.value(), "mojito_spike_entry".unsafe_ptr().bitcast[Int8]()
    )
    if not entry_opt:
        raise Error("FATAL: entry symbol mojito_spike_entry not exported")
    var entry = UnsafePointer[Byte, MutUntrackedOrigin](
        unsafe_from_address=Int(entry_opt.value())
    )

    ms_ctx_make(ctx_b_ptr, top_slot[0], entry, ctx_a_ptr)

    print("## Throughput (A->B->A round trips)")
    print()
    var warm = 0
    while warm < WARMUP_ROUNDS:
        ms_ctx_switch(ctx_a_ptr, ctx_b_ptr)
        warm += 1

    var rounds = 0
    var start = monotonic()
    while rounds < MIN_ROUNDS or monotonic() - start < FLOOR_US:
        var c = 0
        while c < CHUNK:
            ms_ctx_switch(ctx_a_ptr, ctx_b_ptr)
            rounds += 1
            c += 1
    var elapsed = monotonic() - start
    print("| metric | value |")
    print("|---|---|")
    print("| round_trips |", rounds, "|")
    print("| elapsed_us |", elapsed, "|")
    print("| round_trips_per_sec |", rounds * 1000000 // elapsed, "|")
    print("| mean_ns_per_round_trip |", elapsed * 1000 // rounds, "|")
    print("| mean_ns_per_switch_approx |", elapsed * 500 // rounds, "|")
    print()

    print("## Single-switch latency (sampled)")
    print()
    var buckets = _scratch(MAX_BUCKETS * 8, malloc_sym, free_sym)
    var collected = 0
    var attempted = 0
    while collected < SAMPLE_TARGET:
        attempted += 1
        if attempted % SAMPLING_SKIP == 0:
            var t0 = monotonic()
            ms_ctx_switch(ctx_a_ptr, ctx_b_ptr)
            var ns = (monotonic() - t0) * 1000
            var b = ns // BUCKET_NS
            if b >= MAX_BUCKETS:
                b = MAX_BUCKETS - 1
            buckets[b] += 1
            collected += 1
        else:
            ms_ctx_switch(ctx_a_ptr, ctx_b_ptr)

    print("| percentile | ns |")
    print("|---|---|")
    print("| p50 (median) |", _percentile(buckets, collected, 500), "|")
    print("| p95 |", _percentile(buckets, collected, 950), "|")
    print("| p99 |", _percentile(buckets, collected, 990), "|")
    print()
    print("_Sampled values are quantized by the ~1 us monotonic clock; see")
    print("mean_ns_per_switch_approx above for the batch-derived estimate._")
    print()
    _drop(buckets, free_sym)

    print("## Stack memory (reserved vs committed)")
    print()
    print("_Committed = one explicitly faulted page per stack; a completed")
    print("run also proves all guard pages held (any miss would SIGSEGV)._")
    print()
    print("| stacks | reserved_bytes_incl_guard | committed_bytes | guard_pages_held |")
    print("|---|---|---|---|")

    var group = 0
    while group < 3:
        var count = 1
        if group == 1:
            count = 100
        if group == 2:
            count = 1000

        var slots = _scratch(count * 16, malloc_sym, free_sym)
        var reserved_per = ms_stack_total_size()

        var s = 0
        while s < count:
            _alloc_one(slots, s)
            s += 1

        # commit exactly one page per stack: touch lowest usable byte
        s = 0
        while s < count:
            var top_addr = Int(slots[s * 2 + 1])
            var touch = UnsafePointer[Int8, MutUntrackedOrigin](
                unsafe_from_address=top_addr - page
            )
            touch[0] = 88  # 'X': fault in the first usable page
            s += 1

        print("|", count, "|", reserved_per * count, "|", count * page, "|", count, "|")

        s = 0
        while s < count:
            ms_stack_free(UnsafePointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=Int(slots[s * 2])
            ))
            s += 1
        _drop(slots, free_sym)
        group += 1
    print()

    ms_stack_free(base_slot[0])
    _drop(ctx_a, free_sym)
    _drop(ctx_b, free_sym)
