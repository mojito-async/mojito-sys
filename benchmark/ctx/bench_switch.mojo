"""
S5.6 permanent context-switch benchmark (issue #69) — mojito-sys.

Permanent home for the S0 spike switch bench (benchmark/spike/bench_switch.mojo,
issue #13), re-targeted at the PRODUCTION frozen ABI in
native/include/mojito_sys.h (#64/#65/#66): ms_context_init / ms_context_switch
over a stack provided by mjs_stack_alloc. Spec: §38.12 Context benchmarks
(A<->B switch, stack growth/commit), §38.13 regression-gate calibration.

What is measured
----------------
  1. Switch latency (ns per SINGLE ms_context_switch call) as the
     minimum-of-N batch estimate: N independent batches, each running a
     sustained A<->B ping-pong past a floor of both >=1e6 round trips AND
     >=1 s, then per-batch `mean_ns_per_switch = elapsed_us*500/rounds`
     (one round trip == 2 physical switches). The reported
     `switch_latency_ns` is the MINIMUM over the N batches — noise-robust,
     same methodology as the spike (min-of-N under a JIT). The switch path
     IS the register-preservation path: the frozen v2 ABI saves/restores
     x19..x28, fp, lr, d8..d15 and sp (native/include/mojito_sys.h) and
     edition #66 adds the per-record lifecycle tail; switch latency is the
     time of that preserve/restore plus trampoline bookkeeping.
  2. A->B->A round-trip throughput (round trips/sec) — best-of-N.
  3. Round-trip latency percentiles (p50/p95/p99) over sampled round trips,
     bucketed at BUCKET_NS; distribution shape only, not gated.
  4. Stack memory accounting (reserved vs committed, one live stack) —
     informative rows per §38.12 (stack growth/commit); committed bytes are
     exact by construction (this bench touches exactly the pages it counts).

Methodology / same-host note
----------------------------
* Warmup: 10k round trips before every timed batch.
* Floor: each batch runs until BOTH >=1e6 round trips AND >=1s elapse, so
  results never come from an unwarmed micro-run.
* Round-trip definition (amended trampoline semantics): the fiber entry
  loops forever incrementing a counter and yielding straight back to the
  scheduler, so each scheduler-side `ms_context_switch(main_ctx, bench_ctx)`
  is exactly one full A->B->A round trip; the fiber-side counter is
  cross-checked against the scheduler-side count at the end (register-check).
* Clock: wall-clock gettimeofday() as a plain @extern against libSystem —
  the only clock verified correct under the mojo 1.0.0b2 JIT on this host
  (mach_absolute_time runs ~40x slow there; see benchmark/spike/README.md
  b2 caveats). 1 us resolution bounds sampled percentiles from below; batch
  means (millions of round trips) are unaffected.
* Regression gate: benchmark/ctx/gate.sh compares switch_latency_ns and
  round_trips_per_sec against committed benchmark/ctx/baselines.tsv with a
  GENEROUS tolerance (documented b2 flake: under heavy load the JIT can crash
  and scheduler preemption can inflate a batch; min-of-N absorbs most of it).
  Baselines are SAME-HOST only: the gate refuses to compare against a
  baseline recorded on a different (uname)/arch and prints an explicit
  cross-host skip rather than a silent pass or a spurious fail.
* Register preservation is verified functionally by the fiber counter
  cross-check here and exhaustively by tests/s5/ctx/sentinel_probe.c; the
  bench times the preserve/restore path, it does not re-prove the register
  file.

Run (from repo root, after `make` built libmojito_sys.dylib):
  mojo build benchmark/ctx/bench_switch.mojo -Xlinker libmojito_sys.dylib \
      -o build/s5-ctx-bench/bench_switch
  DYLD_LIBRARY_PATH=$PWD build/s5-ctx-bench/bench_switch

or -- the canonical path -- via benchmark/ctx/run.sh, which builds the
packaged dylib, AOT-compiles the bench, runs it, and applies
benchmark/ctx/gate.sh against the committed benchmark/ctx/baselines.tsv.

WHY AOT, NOT `mojo run`: the b2 JIT deterministically traps executing the
PRODUCTION #66 lifecycle trampoline in this environment (verified: `mojo
run` fails on the first ms_context_switch every time; `mojo build` + run is
reliable run-to-run). The spike bench ran under `mojo run` because the
spike-era context ABI had no per-record state machine; the committed
regression gate therefore AOT-compiles so the numbers are deterministic.
The -Xlinker (packaged dylib) mechanism is identical to the Makefile bench
precedent; only the driver mode differs. The spike b2 caveat "the JIT can
crash spuriously" is thereby eliminated from THIS gate.

Scheduler context arming (required by the #66 lifecycle): main_ctx is armed
via ms_context_capture BEFORE the first switch, exactly like the C sentinel
probe (tests/s5/ctx/sentinel_probe.c). Without it the fiber's first return
switch resumes DEAD storage and traps loudly (ms_context_switch brk #0x68);
a zeroed caller buffer is NOT implicitly live under the production ABI.

This LANE's wiring is self-contained under benchmark/ctx/: it does not touch
Makefile or precommit/gate.sh (the S6.7 bench lane owns those edits and will
wire `run_check s5-ctx-bench benchmark/ctx/run.sh`).
"""

from std.memory import stack_allocation
from std.sys.intrinsics import inlined_assembly

comptime LIB = "libmojito_sys.dylib"

# C `void *` transported as a machine word (LP64 Int). Slot cells C reads or
# writes through use MutAnyOrigin (ORIGIN HAZARD, PR#39: post-call loads must
# not be hoisted above the opaque extern call).
comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]
comptime OutSlots = UnsafePointer[Int, MutAnyOrigin]


@extern("gettimeofday")
def _gettimeofday(
    tv: UnsafePointer[Int, MutAnyOrigin],
    tz: UnsafePointer[Byte, MutAnyOrigin],
) abi("C") -> Int:
    ...


# --- production frozen ABI (native/include/mojito_sys.h) ------------------
@extern("mjs_page_size")
def _page_size() abi("C") -> Int32:
    ...


@extern("mjs_stack_alloc")
def _stack_alloc(
    reserve: Int,
    initial_commit: Int,
    guard_bytes: Int,
    out_base: OutSlots,
    out_guard_low: OutSlots,
    out_top: OutSlots,
) abi("C") -> Int32:
    ...


@extern("mjs_stack_free")
def _stack_free(base: OutSlots) abi("C") -> Int32:
    ...


@extern("ms_context_init")
def _ctx_init(
    ctx: BytePtr,
    stack_low: BytePtr,
    stack_size: Int,
    entry: BytePtr,
    userdata: BytePtr,
) abi("C") -> Int32:
    ...


@extern("ms_context_switch")
def _ctx_switch(from_: BytePtr, to: BytePtr) abi("C"):
    ...


@extern("ms_context_capture")
def _ctx_capture(ctx: BytePtr) abi("C"):
    ...


# --- tunables ------------------------------------------------------------
comptime STACK_RESERVE = 65536  # requested reservation for the fiber stack
comptime STACK_COMMIT = 16384  # bytes faulted at allocation
comptime GUARD_BYTES = 16384  # PROT_NONE guard at the bottom
comptime CTX_BUFFER_BYTES = 2048  # per-context scratch (record is 200 B)
comptime WARMUP_ROUNDS = 10_000
comptime MIN_ROUNDS = 1_000_000
comptime FLOOR_US = 1_000_000  # 1 s in us (per batch)
comptime CHUNK = 25_000
comptime REPS = 3  # minimum-of-N batches for switch latency
comptime BEST_SWITCH_NS = 1 << 62  # "infinity" sentinel for argmin
comptime SAMPLING_SKIP = 5
comptime SAMPLE_TARGET = 100_000
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
# by ms_context_switch bookkeeping, so one scheduler-side switch == one full
# A->B->A round trip of pure switch overhead (the body is empty on purpose).
@export("mojito_bench_entry")
def bench_entry(ud: BytePtr) abi("C"):
    var f = ud.bitcast[BenchFrame]()
    while True:
        f[].rounds += 1
        _ctx_switch(f[].bench_ctx, f[].main_ctx)


# Code address of an @export'd abi("C") Mojo callback, as a C function
# pointer (ms_context_entry). `symbol_name` is the @export name WITHOUT the
# Mach-O underscore prefix. (Proven mechanism, spike/mojito_spike.mojo.)
def entry_pointer[symbol_name: String]() -> BytePtr:
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return BytePtr(unsafe_from_address=Int(addr))


def _now_us(tv: UnsafePointer[Int, MutAnyOrigin]) -> Int:
    """Wall-clock epoch microseconds; tv needs >= 4 ints of scratch."""
    var tz = UnsafePointer[Byte, MutAnyOrigin](
        unsafe_from_address=Int(tv) + 16
    )
    _ = _gettimeofday(tv, tz)
    return tv[0] * 1000000 + tv[1]


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


# --- benchmark -------------------------------------------------------------
def main() raises -> None:
    var tv = stack_allocation[4, Int]()

    print("# mojito-sys S5.6 permanent context-switch benchmark (issue #69)")
    print()
    print("## Environment")
    print()
    print("| item | value |")
    print("|---|---|")
    var page = Int(_page_size())
    print("| page_size |", page, "|")
    print("| stack_reserve_bytes |", STACK_RESERVE, "|")
    print("| stack_commit_bytes |", STACK_COMMIT, "|")
    print("| guard_bytes |", GUARD_BYTES, "|")
    print("| n_reps |", REPS, "|")
    print("| warmup_rounds |", WARMUP_ROUNDS, "|")
    print("| min_rounds_per_rep |", MIN_ROUNDS, "|")
    print("| duration_floor_us_per_rep |", FLOOR_US, "|")
    print()

    # scheduler (A) and fiber (B) context blocks, Mojo-side scratch
    var main_buf = stack_allocation[CTX_BUFFER_BYTES // 8, Int]()
    var bench_buf = stack_allocation[CTX_BUFFER_BYTES // 8, Int]()
    var main_ctx = main_buf.bitcast[Byte]()
    var bench_ctx = bench_buf.bitcast[Byte]()

    # B's stack (production mjs_stack_alloc: base / guard_low / top)
    var slots = stack_allocation[3, Int]()
    if _stack_alloc(
        STACK_RESERVE, STACK_COMMIT, GUARD_BYTES, slots, slots + 1, slots + 2,
    ) != 0:
        raise Error("FATAL: mjs_stack_alloc failed for benchmark fiber stack")

    var fs = stack_allocation[1, BenchFrame]()
    fs[] = BenchFrame(bench_ctx, main_ctx)

    var stack_low = BytePtr(unsafe_from_address=slots[1])
    var stack_size = slots[2] - slots[1]
    if _ctx_init(
        bench_ctx,
        stack_low,
        stack_size,
        entry_pointer["mojito_bench_entry"](),
        fs.bitcast[Byte](),
    ) != 0:
        raise Error("FATAL: ms_context_init failed for benchmark fiber")
    # The scheduler context (main_ctx) MUST be armed before its first
    # use: the per-context lifecycle (#66) traps loudly on resume of DEAD
    # storage, so capture arms main_ctx as SUSPENDED (the first switch
    # then saves into it and the fiber's return switch finds it live).
    # Same pattern as the C sentinel probe (tests/s5/ctx/sentinel_probe.c).
    _ctx_capture(main_ctx)
    # ----- A->B->A switch latency: minimum-of-REPS -----------------------
    print("## Throughput and switch latency (min-of-N over", REPS, "reps)")
    print()
    print("_Each batch is one sustained A->B->A ping-pong; one scheduler")
    print("switch == one full A->B->A round trip (two physical switches).")
    print("switch_latency_ns is the per-SINGLE-switch mean of the batch,")
    print("minimum over the", REPS, "batches (noise-robust)._")
    print()
    print("| rep | round_trips | elapsed_us | ns_per_switch | round_trips_per_sec |")
    print("|---|---|---|---|---|")

    var best_switch_ns = BEST_SWITCH_NS
    var best_rps = 0
    var total_scheduler_calls = 0

    var rep = 0
    while rep < REPS:
        var warm = 0
        while warm < WARMUP_ROUNDS:
            _ctx_switch(main_ctx, bench_ctx)
            warm += 1
        total_scheduler_calls += WARMUP_ROUNDS

        var rounds = 0
        var start = _now_us(tv)
        while rounds < MIN_ROUNDS or _now_us(tv) - start < FLOOR_US:
            var c = 0
            while c < CHUNK:
                _ctx_switch(main_ctx, bench_ctx)
                rounds += 1
                c += 1
        var elapsed = _now_us(tv) - start
        total_scheduler_calls += rounds

        var switch_ns = elapsed * 1000 // rounds // 2
        var rps = rounds * 1000000 // elapsed
        if switch_ns < best_switch_ns:
            best_switch_ns = switch_ns
        if rps > best_rps:
            best_rps = rps

        print(
            "|", rep, "|", rounds, "|", elapsed, "|", switch_ns, "|", rps, "|",
        )
        rep += 1

    print()
    print("## Point estimates (gated)")
    print()
    print("| metric | value |")
    print("|---|---|")
    print("| switch_latency_ns |", best_switch_ns, "|")
    print("| round_trips_per_sec |", best_rps, "|")
    print()

    # ---- round-trip latency distribution (sampled, informational) -------
    print("## Round-trip latency (sampled percentiles)")
    print()
    var buckets = stack_allocation[MAX_BUCKETS, Int64]()
    var i = 0
    while i < MAX_BUCKETS:
        buckets[i] = 0
        i += 1

    var collected = 0
    var attempted = 0
    var clamped = 0
    while collected < SAMPLE_TARGET:
        attempted += 1
        if attempted % SAMPLING_SKIP == 0:
            var t0 = _now_us(tv)
            _ctx_switch(main_ctx, bench_ctx)
            var ns = (_now_us(tv) - t0) * 1000
            var b = ns // BUCKET_NS
            if b >= MAX_BUCKETS:
                b = MAX_BUCKETS - 1
                clamped += 1
            buckets[b] += 1
            collected += 1
        else:
            _ctx_switch(main_ctx, bench_ctx)
    total_scheduler_calls += attempted

    print("| percentile | ns |")
    print("|---|---|")
    print("| p50 (median) |", _percentile(buckets, collected, 500), "|")
    print("| p95 |", _percentile(buckets, collected, 950), "|")
    print("| p99 |", _percentile(buckets, collected, 990), "|")
    print("| samples_over_histogram_range |", clamped, "|")
    print()

    # ---- stack memory accounting (per §38.12 growth/commit) -------------
    print("## Stack memory accounting (one live fiber stack)")
    print()
    print("_Reserved = top - base (incl. guard). Committed = bytes guaranteed")
    print("RW at allocation (exact by construction)._")
    print()
    print("| reserved_bytes | committed_bytes | reserved_pages |")
    print("|---|---|---|")
    var reserved_pages = (slots[2] - slots[0]) // page
    print("|", slots[2] - slots[0], "|", STACK_COMMIT, "|", reserved_pages, "|")
    print()

    # cross-check: every scheduler switch advanced the fiber counter once
    var ok = fs[].rounds == total_scheduler_calls
    if not ok:
        raise Error(
            "fiber/scheduler round mismatch: "
            + String(fs[].rounds)
            + " vs "
            + String(total_scheduler_calls)
        )
    print("| fiber_counter_check |", "pass", "|")
    print()

    # machine-parseable rows consumed by benchmark/ctx/gate.sh
    print("BENCH_RESULT switch_latency_ns=", best_switch_ns)
    print("BENCH_RESULT round_trips_per_sec=", best_rps)
    print("BENCH_RESULT register_check=pass")

    # release the fiber stack
    var free_slot = stack_allocation[1, Int]()
    free_slot[] = slots[0]
    _ = _stack_free(free_slot)