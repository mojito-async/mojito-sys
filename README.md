# mojito-sys

Native systems substrate for Mojo: a rigorously tested layer between Mojo code
and OS/machine primitives that lack stable high-level Mojo APIs.

```text
Mojo packages
    |
    v
mojito-sys public Mojo API
    |
    v
public Mojo C-FFI (abi("C"), external_call, C-compatible types)
    |
=================== C ABI FIREWALL ===================
    |
    v
small native substrate: virtual memory, OS threads, TLS,
wait/wake, monotonic clocks, context switching, non-blocking
sockets, readiness/completion polling, platform error translation
```

Design rules (see [docs/mojito-sys_IMPLEMENTATION_SPEC.md](docs/mojito-sys_IMPLEMENTATION_SPEC.md)):

- Mechanism, not policy — no scheduler, no tasks, no channels.
- Platform C ABI is the binary compatibility firewall.
- No hidden allocation on primitive fast paths; explicit blocking behavior.
- Keep live stack addresses stable where users require it.

## Module map

| Package | Phase | Surface |
| --- | --- | --- |
| `mojito_sys.abi` | S1 | ABI negotiation (`abi_version`), decoded errno raises, callbacks, dynamic libraries |
| `mojito_sys.memory` | S1 | Pages (`page`), stacks (`stack`), virtual memory (`virtual_memory`) |
| `mojito_sys.io` | S1 | Raw descriptor handles (`io.handle`) |
| `mojito_sys.thread` | S2 | OS threads (`NativeThread`, `spawn_native_thread`), TLS keys (`NativeTlsKey`), CPU topology + affinity (`cpu_logical_count`, `CpuSet`) |
| `mojito_sys.time` | S4 | Monotonic clock (`monotonic`), durations (`duration`) |

## Status

**Phase S0 — external-stack execution feasibility spike (go/no-go gate).**
No broad infrastructure work starts until `spike/context_switch/` proves that
ordinary Mojo frames survive a native stack switch through the public C ABI.

Spike contract: hypothesis, prototype scope, semantic tests S0-T1..T14,
benchmarks, deliverables, and GO/CONDITIONAL GO/NO-GO criteria live in spec
Section 6 and in [spike/context_switch/README.md](spike/context_switch/README.md).

## Toolchain

Mojo 1.0.0b2 baseline (`mojolang` Homebrew package from the local
`homebrew-mojolang` tap).

## Non-goals

No Scope/Task/JoinHandle, structured concurrency, work stealing, cancellation,
channels, futures, async/await adapters, timers, HTTP, actors — those belong to
[`mojito-async`](https://git.opsite.ca/mojito/mojito-async).
