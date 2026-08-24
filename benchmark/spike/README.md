# S0 context-switch benchmark (issue #13)

Benchmarks the frozen context-switch ABI from
[`spike/context_switch/CONTRACT.md`](../../spike/context_switch/CONTRACT.md).

## Run

From the repo root (after `make` built `libmojito_spike.dylib`):

```sh
mojo run -I spike/context_switch \
    -Xlinker libmojito_spike.dylib \
    -Xlinker /usr/lib/libSystem.B.dylib \
    benchmark/spike/bench_switch.mojo
```

NOTE: the current `make bench` target (foundation #8) invokes plain
`mojo run benchmark/spike/bench_switch.mojo`, which is missing both the
`-I` import path and the two `-Xlinker` flags — it fails with
"unable to locate module 'mojito_spike'". Flagged to #8; until the target
is fixed use the command above.

## What is measured

| Metric | Definition |
|---|---|
| Round trips/sec | Full A→B→A scheduler round trips per second. With the amended trampoline semantics (`to.return_to = caller`, trampoline tail-switches back after `entry(userdata)`), one `ms_ctx_switch(&main, &bench)` call from the scheduler is exactly one round trip. |
| mean ns / switch | Batch-derived: total elapsed ÷ round trips ÷ 2. The authoritative point estimate; immune to clock-granularity quantization. |
| p50 / p95 / p99 | Percentiles over individually timed switches (every 5th switch sampled) bucketed at 25 ns. The monotonic clock on macOS has ~1 µs granularity, so individual samples quantize — read these for distribution shape, the batch mean for absolute level. |
| reserved bytes | `ms_stack_total_size()` per stack × stack count. Includes the PROT_NONE guard page. |
| committed bytes | Bytes actually faulted: the benchmark touches exactly one usable page per stack, so committed = stacks × page size, exact by construction. |
| guard pages held | A completed memory section proves every guard page held for every allocation — a single miss would SIGSEGV the run. |

## Statistical sanity

* **Warmup**: 10,000 round trips before any measurement.
* **Floor**: measurement runs until BOTH ≥1,000,000 round trips AND ≥2 s
  have elapsed, so results never come from an unwarmed micro-run.
* **Sampling overhead**: only 1 in 5 switches carries clock-read overhead
  during the latency phase; the throughput phase has zero per-iteration
  clock reads.

Stack sizes default to 64 KiB requested (`STACK_BYTES` in
`bench_switch.mojo`); page size comes from `ms_page_size()` at runtime.

## Results

**Machine**: Apple M5 (arm64), macOS 25.5.0, mojo 1.0.0b2 (2cf4d08a),
2026-08-23. Stack: 64 KiB requested; page size 16384.

Throughput (2 s floor, 10k warmup):

| metric | value |
|---|---|
| round_trips | 167700000 |
| elapsed_us | 2000295 |
| round_trips_per_sec | 83837633 |
| mean_ns_per_round_trip | 11 |
| mean_ns_per_switch_approx | 5 |

Single-switch latency (sampled, 1 us clock quantization):

| percentile | ns |
|---|---|
| p50 (median) | 12 |
| p95 | 12 |
| p99 | 1012 |

Stack memory:

| stacks | reserved_bytes_incl_guard | committed_bytes | guard_pages_held |
|---|---|---|---|
| 1 | 81920 | 16384 | 1 |
| 100 | 8192000 | 1638400 | 100 |
| 1000 | 81920000 | 16384000 | 1000 |

Fiber/scheduler counter cross-check: pass (168710000 rounds).

Reading: a full A->B->A round trip costs ~11-12 ns (~6 ns per
`ms_ctx_switch`), i.e. tens of cycles — consistent with the ~30-register
callee-saved save/restore in `aarch64_switch.S`. The p50/p95 samples sit at
the clock's quantization floor (sub-us switches read as 0 us -> bucket
center 12 ns); p99 catches scheduler preemptions at ~1 us. Reserved bytes =
64 KiB usable + one 16 KiB guard page per stack, matching
`ms_stack_total_size()`; committed bytes are exactly one faulted page per
stack by construction, and a completed memory section proves all guard
pages held for all 1101 allocations.

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
2. **Entry callback** — `ms_ctx_make` needs a C-ABI entry pointer. This
   bench resolves `mojito_spike_entry` via dlsym from libmojito_spike.dylib.
   The canonical b2-legal entry-callback mechanism is #10's deliverable;
   this seam will be folded to whatever #10 lands (tracked on #13).
3. **OS-level RSS not reported in-process** — mojo 1.0.0b2's
   `inlined_assembly` (the only way to make multi-argument extern calls
   from Mojo today, since `std.sys._libc` exposes almost nothing) crashes
   the JIT in two independent ways:
   * any call with more than 4 operands (result + 3 inputs), even if the
     extra inputs are unused;
   * any inline-asm string containing a load instruction (`ldr xN, [...]`).
   Mach `task_info` needs 4 arguments, which requires one of the above.
   Repro available on request. Until fixed, capture RSS externally:

   ```sh
   # sample RSS while make bench runs (values in KiB):
   while true; do ps -o rss= -p $!; sleep 0.2; done
   ```
4. **Clock granularity** — see the percentile note above.

These toolchain findings should also be recorded by #10 under
"Observed Mojo/compiler assumptions" in SPIKE_REPORT.md per the contract
amendment.
