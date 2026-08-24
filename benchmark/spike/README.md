# S0 context-switch benchmark (issue #13)

Benchmarks the frozen context-switch ABI from
[`spike/context_switch/CONTRACT.md`](../../spike/context_switch/CONTRACT.md)
through the b2-legal bindings of `spike/context_switch/mojito_spike.mojo`.

## Run

From the repo root (after `make` built `libmojito_spike.dylib`):

```sh
mojo run -I spike/context_switch \
    -Xlinker libmojito_spike.dylib \
    benchmark/spike/bench_switch.mojo
```

or `make bench` from the repo root. libc symbols (`gettimeofday`) used by
the bench resolve from images already loaded in the process — no extra
`-Xlinker` is needed.

## What is measured

| Metric | Definition |
|---|---|
| Round trips/sec | Full A→B→A scheduler round trips per second. With the amended trampoline semantics (`to.return_to = caller`, trampoline tail-switches back after `entry(userdata)`), one `ms_ctx_switch(&main, &bench)` call from the scheduler is exactly one round trip. |
| mean ns / round trip | Batch-derived: total elapsed ÷ round trips. The authoritative point estimate; immune to clock-granularity quantization. `mean_ns_per_switch_approx` is that number ÷ 2 and is explicitly an approximation. |
| p50 / p95 / p99 | Percentiles over individually timed **round trips** (every 5th switch sampled) bucketed at 25 ns. Wall-clock resolution is 1 µs, so sub-microsecond samples quantize to the first bucket (bucket centers carry a +12 ns bias for those); read percentiles for distribution shape, the batch mean for absolute level. |
| reserved bytes | MEASURED as the live-sum delta of `ms_stack_total_size()` across each allocation loop (the function returns the total of all currently live stacks, not a per-stack constant). Includes each stack's PROT_NONE guard page. |
| committed bytes | Bytes actually faulted: the benchmark touches exactly the pages it counts, nothing more. Exact by construction. |

Guard pages are deliberately NOT exercised by this benchmark — touching a
guard page faults the process. Guard behavior (fault on access into
`[base, base+ps)`) is covered by tests-b T13.

## Statistical sanity

* **Warmup**: 10,000 round trips before any measurement.
* **Floor**: measurement runs until BOTH ≥1,000,000 round trips AND ≥2 s
  have elapsed, so results never come from an unwarmed micro-run.
* **Sampling overhead**: only 1 in 5 switches carries clock-read overhead
  during the latency phase; the throughput phase has zero per-iteration
  clock reads. Samples over the histogram range are clamped and counted
  (`samples_over_histogram_range` row).
* **Controlled growth**: a dedicated section commits 1 → 2 → 4 pages per
  stack (capped at the usable page count) on the same live stacks;
  reservation must stay flat while committed scales linearly.

Stack sizes default to 64 KiB requested (`STACK_BYTES` in
`bench_switch.mojo`); page size comes from `ms_page_size()` at runtime.

## Results

**Machine**: Apple M5 (arm64), macOS 25.5.0, mojo 1.0.0b2 (2cf4d08a),
2026-08-23. Stack: 64 KiB requested; page size 16384.

Throughput (2 s floor, 10k warmup):

| metric | value |
|---|---|
| round_trips | 165950000 |
| elapsed_us | 2000125 |
| round_trips_per_sec | 82969814 |
| mean_ns_per_round_trip | 12 |
| mean_ns_per_switch_approx | 6 |

Round-trip latency (sampled):

| percentile | ns |
|---|---|
| p50 (median) | 12 |
| p95 | 12 |
| p99 | 1012 |
| samples_over_histogram_range | 0 |

Stack memory:

| stacks | reserved_bytes_incl_guard | reserved_pages_per_stack | committed_bytes |
|---|---|---|---|
| 1 | 81920 | 5 | 16384 |
| 100 | 8192000 | 5 | 1638400 |
| 1000 | 81920000 | 5 | 16384000 |

Committed bytes under controlled growth (64 stacks):

| stacks | reserved_bytes_incl_guard | touch_depth_pages | committed_bytes |
|---|---|---|---|
| 64 | 5242880 | 1 | 1048576 |
| 64 | 5242880 | 2 | 2097152 |
| 64 | 5242880 | 4 | 4194304 |

Fiber/scheduler counter cross-check: pass (166960000 rounds).

Reading: a full A→B→A round trip costs ~11-13 ns (~6 ns per `ms_ctx_switch`
call) — consistent with the ~30-register callee-saved save/restore in
`aarch64_switch.S`. The p50/p95 samples sit at the clock's quantization
floor; p99 catches scheduler preemptions at ~1 us. Reservation is flat at
5 pages/stack (4 usable + 1 guard) while committed bytes scale linearly
with deliberate touch depth.

## OS-level RSS

RSS is NOT reported from inside this process. Mach `task_info` requires a
4-argument extern call, which mojo 1.0.0b2 inline asm cannot express yet
(see "b2 JIT caveats"). Capture it externally around a run instead —
background the bench first so `$PID` is real:

```sh
mojo run -I spike/context_switch -Xlinker libmojito_spike.dylib \
    benchmark/spike/bench_switch.mojo &
PID=$!
while kill -0 $PID 2>/dev/null; do ps -o rss= -p $PID; sleep 0.2; done
```

## b2 JIT caveats

Observed on 1.0.0b2; worth recording in #10's SPIKE_REPORT:

* `std.time.monotonic()` does not advance within a process.
* `mach_absolute_time` advances ~40x slower than wall time under the JIT
  (both `@extern`-declared and dlsym'd); `gettimeofday` behaves correctly.
* Busy loops whose accumulators are compile-time-computable get
  constant-folded entirely (loop deleted) — micro-benchmark bodies must be
  data-dependent.
* Under heavy machine load the JIT can crash spuriously; re-run before
  diagnosing.

## Status history

* **RED** (commit 1): bench written against the frozen binding names before
  any implementation existed; failed deterministically with
  `unable to locate module 'mojito_spike'`.
* **GREEN**: rebased onto main after #8/#9/#10 landed; entry seam folded to
  the shipped `@export` + `entry_pointer[symbol]()` mechanism; full run
  passes end-to-end with the numbers above.

## Known seams & limitations

1. **Bindings import** — the six frozen binding names are imported from
   `spike/context_switch/mojito_spike.mojo` (owned by #10). If #10 lands
   with different internal structure but the same exported names, nothing
   changes here.
2. **Entry callback** — resolved via the shipped `entry_pointer` mechanism
   against this file's own `@export("mojito_bench_entry")` callback.
3. **Clock resolution** — 1 us wall clock bounds sampled percentiles from
   below; batch means are unaffected.
4. **OS-level RSS** — external capture only, see above.
