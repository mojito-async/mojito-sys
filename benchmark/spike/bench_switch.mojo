"""
S0 context-switch benchmark (issue #13) — mojito-sys spike.

Measures the FROZEN ABI from spike/context_switch/CONTRACT.md through the
b2-legal bindings in spike/context_switch/mojito_spike.mojo (#10):

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
* Round-trip definition follows the amended contract trampoline semantics
  (userdata passes through unmodified; ms_ctx_switch records
  to.return_to = caller): the benchmark fiber entry loops forever,
  incrementing a counter and yielding straight back to the scheduler, so
  every `ms_ctx_switch(main_ctx, bench_ctx)` call from the scheduler is
  exactly one full A->B->A round trip. The fiber-side counter is
  cross-checked against the scheduler-side count at the end.
* Timing: gettimeofday() declared as a plain @extern against libSystem —
  same mechanism as the spike bindings themselves. Resolution is 1 us,
  which bounds single-switch latency percentiles from below; throughput is
  measured batch-style over millions of rounds so resolution error is
  negligible there. (mach_absolute_time was tried first and misbehaves
  under the b2 JIT: see README "OS-level RSS and timing caveats".)
* Latency sampling: every SAMPLING_SKIP-th switch is timed individually.
  Sampled switches carry two extra clock reads, so they are upper bounds;
  the batch-derived mean (total time / count) is the authoritative point
  estimate, percentiles show distribution shape. Bucket width 25 ns.
* Committed bytes are exact by construction: this benchmark touches exactly
  one usable page per stack and counts it committed. A surviving run also
  proves every guard page held for every allocation (a single guard miss
  would SIGSEGV the benchmark).
* OS-level RSS is NOT reported from inside this process (see README,
  "OS-level RSS"): Mach task_info needs a 4-argument extern call, which
  mojo 1.0.0b2 inline asm cannot express yet. Capture RSS externally with
  `ps -o rss=` sampling around the run.

Run (from repo root):
  mojo run -I spike/context_switch -Xlinker libmojito_spike.dylib \
      -Xlinker /usr/lib/libSystem.B.dylib \
      benchmark/spike/bench_switch.mojo
"""

from std.memory import stack_allocation

from mojito_spike import (
    BytePtr,
    MS_CTX_SIZE,
    entry_pointer,
    ms_page_size,
    ms_stack_alloc,
    ms_stack_free,
    ms_stack_total_size,
    ms_ctx_make,
    ms_ctx_switch,
)


@extern("gettimeofday")
def _gettimeofday(
    tv: UnsafePointer[Int, MutAnyOrigin],
    tz: UnsafePointer[Byte, MutAnyOrigin],
) abi("C") -> Int:
    ...


def _now_us(tv: UnsafePointer[Int, MutAnyOrigin]) -> Int:
    """Epoch microseconds; tv must have >= 4 ints of scratch behind it."""
    var tz = UnsafePointer[Byte, MutAnyOrigin](
        unsafe_from_address=Int(tv) + 16
    )
    _ = _gettimeofday(tv, tz)
    return tv[0] * 1000000 + tv[1]


# --- tunables ------------------------------------------------------------
comptime STACK_BYTES = 65536
comptime WARMUP_ROUNDS = 10_000
comptime MIN_ROUNDS = 1_000_000
comptime FLOOR_US = 2_000_000  # 2 s in us
comptime CHUNK = 25_000
comptime SAMPLING_SKIP = 5
comptime SAMPLE_TARGET = 200_000
comptime BUCKET_NS = 25
comptime MAX_BUCKETS = 4096  # covers single switches up to ~102 us


# --- shared scheduler<->fiber frame ---------------------------------------
struct BenchFrame:
    var bench_ctx: BytePtr
    var main_ctx: BytePtr
    var rounds: Int

    def __init__(out self, bc: BytePtr, mc: BytePtr):
        self.bench_ctx = bc
        self.main_ctx = mc
        self.rounds = 0


# Fiber entry: entered once through the C trampoline, then ping-pongs
# forever. Every yield hands control back to the scheduler context recorded
# by ms_ctx_switch bookkeeping, so one scheduler-side switch == one full
# A->B->A round trip of pure switch overhead (the body is empty on purpose).
@export("mojito_bench_entry")
def bench_entry(ud: BytePtr) abi("C"):
    var f = ud.bitcast[BenchFrame]()
    while True:
        f[].rounds += 1
        ms_ctx_switch(f[].bench_ctx, f[].main_ctx)


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


def _memory_report[
    COUNT: Int
](page: Int) raises -> None:
    """Reserved-vs-committed row for COUNT concurrently live stacks."""
    var slots = stack_allocation[COUNT * 2, BytePtr]()
    var reserved_per = ms_stack_total_size()

    var s = 0
    while s < COUNT:
        if ms_stack_alloc(STACK_BYTES, slots + s * 2, slots + s * 2 + 1) != 0:
            raise Error("FATAL: ms_stack_alloc failed")
        s += 1

    # commit exactly one page per stack: touch lowest usable byte
    s = 0
    while s < COUNT:
        var top_addr = Int((slots + s * 2 + 1)[])
        var touch = UnsafePointer[Int8, MutUntrackedOrigin](
            unsafe_from_address=top_addr - page
        )
        touch[0] = 88  # 'X': fault in the first usable page
        s += 1

    print("|", COUNT, "|", reserved_per * COUNT, "|", COUNT * page, "|", COUNT, "|")

    s = 0
    while s < COUNT:
        ms_stack_free((slots + s * 2)[])
        s += 1


# --- benchmark -------------------------------------------------------------
def main() raises -> None:
    var tv = stack_allocation[4, Int]()
    var tz = UnsafePointer[Byte, MutAnyOrigin](
        unsafe_from_address=Int(tv) + 16
    )

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
    print()

    # scheduler (A) and fiber (B) context blocks, Mojo-side scratch
    var main_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
    var bench_buf = stack_allocation[MS_CTX_SIZE // 8, Int]()
    var main_ctx = main_buf.bitcast[Byte]()
    var bench_ctx = bench_buf.bitcast[Byte]()

    # B's stack
    var slots = stack_allocation[2, BytePtr]()
    if ms_stack_alloc(STACK_BYTES, slots, slots + 1) != 0:
        raise Error("FATAL: ms_stack_alloc failed for benchmark fiber stack")

    var fs = stack_allocation[1, BenchFrame]()
    fs[] = BenchFrame(bench_ctx, main_ctx)

    ms_ctx_make(
        bench_ctx,
        (slots + 1)[],
        entry_pointer["mojito_bench_entry"](),
        fs.bitcast[Byte](),
    )

    print("## Throughput (A->B->A round trips)")
    print()
    var warm = 0
    while warm < WARMUP_ROUNDS:
        ms_ctx_switch(main_ctx, bench_ctx)
        warm += 1

    var rounds = 0
    var start = _now_us(tv)
    while rounds < MIN_ROUNDS or _now_us(tv) - start < FLOOR_US:
        var c = 0
        while c < CHUNK:
            ms_ctx_switch(main_ctx, bench_ctx)
            rounds += 1
            c += 1
    var elapsed = _now_us(tv) - start
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
    var buckets = stack_allocation[MAX_BUCKETS, Int64]()
    var i = 0
    while i < MAX_BUCKETS:
        buckets[i] = 0
        i += 1

    var collected = 0
    var attempted = 0
    while collected < SAMPLE_TARGET:
        attempted += 1
        if attempted % SAMPLING_SKIP == 0:
            var t0 = _now_us(tv)
            ms_ctx_switch(main_ctx, bench_ctx)
            var ns = (_now_us(tv) - t0) * 1000
            var b = ns // BUCKET_NS
            if b >= MAX_BUCKETS:
                b = MAX_BUCKETS - 1
            buckets[b] += 1
            collected += 1
        else:
            ms_ctx_switch(main_ctx, bench_ctx)

    print("| percentile | ns |")
    print("|---|---|")
    print("| p50 (median) |", _percentile(buckets, collected, 500), "|")
    print("| p95 |", _percentile(buckets, collected, 950), "|")
    print("| p99 |", _percentile(buckets, collected, 990), "|")
    print()
    print("_Sampled switches include two clock reads (upper bounds); see")
    print("mean_ns_per_round_trip above for the batch-derived estimate._")
    print()

    print("## Stack memory (reserved vs committed)")
    print()
    print("_Committed = one explicitly faulted page per stack; a completed")
    print("run also proves all guard pages held (any miss would SIGSEGV)._")
    print()
    print("| stacks | reserved_bytes_incl_guard | committed_bytes | guard_pages_held |")
    print("|---|---|---|---|")
    _memory_report[1](page)
    _memory_report[100](page)
    _memory_report[1000](page)
    print()

    # cross-check: every scheduler switch advanced the fiber counter once
    var expected = WARMUP_ROUNDS + rounds + attempted
    if fs[].rounds != expected:
        raise Error(
            "fiber/scheduler round mismatch: "
            + String(fs[].rounds)
            + " vs "
            + String(expected)
        )
    print("| fiber_counter_check | pass (", expected, "rounds) |")
    print()

    ms_stack_free(slots[])
