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

## Status

**Phase S0 — external-stack execution feasibility spike (go/no-go gate).**
No broad infrastructure work starts until `spike/context_switch/` proves that
ordinary Mojo frames survive a native stack switch through the public C ABI.

Spike contract: hypothesis, prototype scope, semantic tests S0-T1..T14,
benchmarks, deliverables, and GO/CONDITIONAL GO/NO-GO criteria live in spec
Section 6 and in [spike/context_switch/README.md](spike/context_switch/README.md).

## S1 stress lane charter

`tests/s1/stress` currently owns memory-only coverage (guarded-stack
geometry, downward growth via `mjs_vm_commit`, non-moving frames, guard
faults). Its charter is deliberately broader from S2 on: cross-domain
stress interleaving stack growth with context switching, callbacks, and
error propagation once those lanes land (#29/#30/#35). The lane keeps its
`tests/s1/stress` location; this note records the scope so the directory
name does not overpromise today.

## Toolchain

Mojo 1.0.0b2 baseline (`mojolang` Homebrew package from the local
`homebrew-mojolang` tap).

## Non-goals

No Scope/Task/JoinHandle, structured concurrency, work stealing, cancellation,
channels, futures, async/await adapters, timers, HTTP, actors — those belong to
[`mojito-async`](https://git.opsite.ca/mojito/mojito-async).
