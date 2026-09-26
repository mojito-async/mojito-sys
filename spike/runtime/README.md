# M1.3 spike — runtime: native thread entry, TLS and a native poller from Mojo

Part of the Mojo-first migration's Phase 1 spike (epic #121, spec §6). This
leg proves the runtime edge `mojito-async` needs: a thread that can run
Mojo code, thread-local storage the runtime can reach from it, and a
poller that thread can block in — all driven directly from Mojo, with no
`native/posix/{mjs_thread,mjs_tls,mjs_poller,mjs_epoll}.c` anywhere in the
chain. Contract source of truth:
`docs/mojito-sys_MOJO_MIGRATION_SPEC.md` §2.2, §6, §8, and issue #126's
own body.

## Question

Can a Mojo `abi("C")` function be the ACTUAL `pthread_create` start
routine (not merely the callee of a C trampoline, which is what
`mojito_sys.thread.thread.spawn_native_thread` already does via
`mjs_thread_spawn`)? Can Mojo mint and own a raw `pthread_key_t` itself
(create/set/get/destroy) with the exit destructor firing correctly? Can
Mojo drive a real kqueue and a real epoll poller end to end — register,
modify, unregister, wait (with and without a timeout), and wake a blocked
wait from another Mojo-spawned thread — with `struct kevent` /
`struct epoll_event` built directly from Mojo?

## Scope

```text
spike/runtime/oracle.c               C oracle: opaque pthread_t/pthread_key_t
                                      size+align facts, kqueue/epoll/eventfd
                                      platform constants, a C-side TLS
                                      cross-language probe, and an
                                      exact-byte-count write() wrapper
                                      (eventfd needs exactly 8 bytes; a
                                      hand-declared @extern("write") would
                                      conflict with std.io, mojito-sys#195)
spike/runtime/externs_leaf.mojo       pure LEAF module: @extern bindings for
                                      pthread_create/join/self,
                                      pthread_key_*, kqueue/kevent,
                                      epoll_create1/ctl/wait, eventfd,
                                      pipe/close/read, plus oracle.c's
                                      surface and the alloc_probe_shim.c
                                      counters — non-raising probe_* shims
                                      throughout (repo convention, #49)
spike/runtime/thread_test.mojo        native thread entry: arg/result round
                                      trip, __del__ vs __deinit__ on a
                                      spawned thread, contained raise,
                                      thread identity, 50-cycle smoke
spike/runtime/tls_test.mojo           TLS: create/set/get/destroy,
                                      per-thread isolation, exit
                                      destructor, cross-language
                                      visibility, allocation-free get
                                      (macOS, dyld-interposed count)
spike/runtime/poller_kqueue_test.mojo kqueue poller: add/modify/remove/
                                      wait/wake, verbatim token passthrough
spike/runtime/poller_epoll_test.mojo  epoll poller: same shape, epoll_event
                                      byte layout MEASURED at runtime (not
                                      hardcoded — see below)
docs/defects/m1-3-*.mojo              minimal reproducer for the one Mojo
                                       compiler defect this leg found and
                                       filed (mojito-sys#201)
```

Developed on macOS arm64 (Darwin 25.6.0), Mojo 1.0.0b2 (2cf4d08a),
homebrew `mojolang` tap — **and additionally verified for real on native
Linux/AArch64** via a local Docker container (Docker Desktop's own
`linux/arm64` engine on this arm64 dev host, so genuinely native, not
QEMU/Rosetta-emulated), installing the identical `mojo-compiler-1.0.0b2`
build for `linux-aarch64` through this repo's own
`.github/scripts/install-mojo.sh`. This is NOT part of the automated
`run.sh`/CI path (no repo file drives it; see "Linux verification" below
for exact commands to reproduce it) — it is what let `thread_test.mojo`,
`tls_test.mojo`, and, most notably, `poller_epoll_test.mojo` all run for
**real**, not just "coded and believed correct," on Linux for this leg,
which is more Linux signal than #124's sibling ABI leg got (that leg's own
`suite-linux` CI lane never got past `make` at all — see "Known CI
condition" below).

## What's proven, measured on macOS arm64 AND on native Linux/AArch64 (docker)

- **Thread**: `pthread_create` called directly from Mojo, with a Mojo
  `abi("C")` `@export`'d function as the literal start routine (no C
  trampoline). Argument pointer arrives intact and mutations through it
  survive; the entry's return value survives `pthread_join` exactly,
  independently; the thread exits cleanly. Verified with 3 distinct
  argument seeds and 50 sequential spawn/join cycles (leak-clean smoke).
- **Thread identity**: `pthread_self()` differs between the spawned
  thread and the main thread, and is stable within one thread.
- **Value construction/destruction on the spawned thread**: `__del__`
  fires exactly like it does on the main thread (construct/destruct
  balance returns to 0), including along a `try`/`except`-containment
  path. `__deinit__` does NOT fire on scope exit — on the spawned thread
  OR the main thread — an exact parity match with
  `mojito_sys/ctx/context.mojo`'s own already-documented b2 finding
  ("b2 1.0.0b2 does not invoke `__deinit__` on locals"), so this is the
  acceptance criterion's "or the difference is documented" branch, not a
  new defect.
- **Raising containment**: `abi("C") raises` is rejected AT PARSE TIME
  ("'abi("C")' function may not be marked 'raises'; remove 'raises' or
  use 'abi("Mojo")'") — verified directly. There is therefore no way to
  even express the unsafe shape #126 asks about; the only expressible
  pattern is catching internally and reporting through the ordinary
  return value, which `thread_test.mojo` proves works (no crash, correct
  status, cleanup still balanced, process stays alive) on both the
  no-raise and raise paths.
- **TLS**: `pthread_key_create`/`_delete`/`_get`/`_set` called directly
  from Mojo. Create/set/get/destroy round trip on the main thread;
  per-thread isolation (a value bound by a spawned worker is invisible to
  the main thread's own binding for the same key, and vice versa); the
  destructor registered at create() fires EXACTLY ONCE on the binding
  thread's exit, with the bound VALUE (not the key); cross-language
  visibility BOTH directions (a value set from Mojo is read by a real C
  function via the same key, and a value set from C is read by Mojo) —
  proven via `oracle_tls_set_from_c`/`oracle_tls_get_from_c`, not assumed
  from "they share a registry."
- **TLS allocation-free get (macOS)**: `pthread_getspecific` called 1000
  times in a loop allocates exactly zero bytes, measured via
  `tools/migration_baseline/alloc_probe_shim.c`'s dyld-interposing
  malloc/calloc/realloc counter (spec SYS-4, §18's "measured, not
  asserted" methodology) — reused directly from M1.1's own baseline
  tooling, not reinvented. Reports SKIP (not a false PASS) on Linux, where
  the shim's dyld-interposing mechanism does not exist.
- **kqueue poller** (macOS): `kqueue`/`kevent` called directly from Mojo.
  Add/modify/remove/wait/wake all work exactly per
  `native/posix/mjs_poller.c`'s own documented semantics: a short timeout
  on nothing-ready reports 0 events; a write makes wait() report exactly 1
  event with the fd and the EXACT verbatim 64-bit token; a modify
  (re-register) UPSERTS the token (last write wins, matching kqueue's own
  `EV_ADD` re-add-updates semantics); unregister stops delivery even after
  the fd becomes ready again; a blocked (infinite-timeout) wait is
  released promptly by `wake()` from a SEPARATE Mojo-spawned thread and
  reports ZERO real events once the internal `EVFILT_USER` wake knote is
  filtered out (mirroring `mjs_poller_wait`'s own "wake deliveries never
  occupy an out slot").
- **epoll poller** (Linux, verified for real via the docker container):
  the identical add/modify/remove/wait/wake shape against
  `epoll_create1`/`epoll_ctl`/`epoll_wait` + `eventfd`, called directly
  from Mojo. Level-triggered delivery confirmed (a drained fd reports 0 on
  the next poll); `EPOLL_CTL_ADD` on an already-registered fd degrades to
  an upsert exactly like `native/posix/mjs_epoll.c`'s own
  `mjs_epoll_set` does; a blocked wait is released by an `eventfd` wake
  from another Mojo-spawned thread with zero real events after filtering.
- **`epoll_event` byte layout, measured live on native Linux/AArch64,
  resolving a fact #124's own FINDINGS.md flagged as "unverified anywhere
  reachable from this repo, on any host"**: size 16, `events` at offset
  0, `data` at offset 8, `packed=0` (naturally aligned, NOT the
  x86-64-glibc-packed 12-byte form) — matching the natural-alignment
  prediction exactly. `poller_epoll_test.mojo` never hardcodes this
  layout; it reads `oracle_sizeof_epoll_event()` /
  `oracle_offset_epoll_event_{events,data}()` at runtime and pokes/reads
  fields at the measured offsets, so it is correct on either packing
  without a compile-time branch.
- **`entry_pointer` portability, a genuinely new finding this leg needed
  and verified**: the repo-wide `adrp`/`add` + `@PAGE`/`@PAGEOFF` idiom
  (`tests/s1/abi/callbacks/conformance_test.mojo` and every S2/S3/S6 test
  that spawns a thread) is Apple arm64 Mach-O-specific syntax and fails to
  PARSE on Linux ("unexpected token in argument list" /
  "invalid specifier '@PAGEOFF'") — confirmed directly, and the process
  that reaches `pthread_create` with the resulting garbage address
  segfaults. The ELF/AArch64 form needs no leading `_` symbol prefix and
  `:lo12:` instead of `@PAGEOFF` (a plain, unsuffixed `adrp` for the high
  part); `entry_pointer` in every file here selects between the two
  templates with a `comptime if CompilationTarget().is_macos()`, verified
  working on BOTH platforms. This is real, useful signal beyond #124's own
  version of this idiom, which was Apple-arm64-only and never actually ran
  on any Linux host either (blocked by the same CI wall noted below) — an
  x86-64 form (which would need a THIRD, ISA-different `lea`-based
  template) was not attempted.

## Compiler defects/gaps found and filed

One, with a minimal reproducer under `docs/defects/` and filed against
this repo:

- **mojito-sys#201** — `def __moveinit__(out self, owned existing: Self):`
  parses and compiles when the struct lives in a file that gets
  IMPORTED, but fails to parse the byte-for-byte identical source when
  run directly as the `mojo run` entry file. Already present, unnoticed,
  in this repo's own `mojito_sys/io/poller.mojo`/`io/handle.mojo` (which
  use this `owned` form instead of the repo's dominant
  `mut self, mut existing: Self` shape) — nothing has hit it because
  nothing `mojo run`s either file directly, only imports it.

Two things this leg deliberately did NOT file as new defects, because
they are either an already-documented repo finding or a working,
by-design compiler guardrail rather than a gap:

- `__deinit__` not firing on scope exit is `mojito_sys/ctx/context.mojo`'s
  own pre-existing, already-documented b2 finding; this leg only confirms
  it holds with identical parity on a spawned pthread thread.
- `abi("C") raises` being rejected at parse time is a correct, working
  safety guardrail (it is literally what makes the "must not unwind into
  C" contract enforceable at compile time), not a gap to report.

## Running the suite

```sh
cd spike/runtime
./run.sh
```

or from the repo root: `MOJO=mojo CC=cc spike/runtime/run.sh`.

## Linux verification (native AArch64, via Docker — not part of run.sh/CI)

This is how the Linux/AArch64 results above were produced; it needs
Docker Desktop with a native `linux/arm64` engine (true on an Apple
Silicon host — NOT emulation) and is a manual, reproducible recipe, not a
wired-in CI lane (see "Known CI condition" for why a wired-in Linux CI
lane cannot reach this leg at all today):

```sh
docker run -d --platform linux/arm64 --name mojito-mojo-dev \
  -v "$(pwd)":/src:ro ubuntu:22.04 sleep infinity
docker exec mojito-mojo-dev bash -c \
  "apt-get update -qq && apt-get install -y -qq build-essential ca-certificates curl unzip zstd python3 gcc"
docker exec mojito-mojo-dev bash -c \
  "mkdir -p /work && cp -a /src/. /work/ && cd /work && ./.github/scripts/install-mojo.sh"
docker exec mojito-mojo-dev bash -c '
  export MODULAR_HOME=/root/mojo-toolchain/share/max PATH=/root/mojo-toolchain/bin:$PATH
  cd /work/spike/runtime
  gcc -O2 -g -fPIC -shared -D_GNU_SOURCE -o .build/liboracle.so oracle.c
  mojo run -I . -Xlinker .build/liboracle.so thread_test.mojo
  mojo run -I . -Xlinker .build/liboracle.so tls_test.mojo
  mojo run -I . -Xlinker .build/liboracle.so poller_kqueue_test.mojo   # expect ENVIRONMENT
  mojo run -I . -Xlinker .build/liboracle.so poller_epoll_test.mojo
'
```

x86-64 Linux was NOT attempted (would need Docker's QEMU-emulated
`linux/amd64` on this arm64 host, plus a third `entry_pointer` asm
template for x86-64's different ISA — genuinely more work than this
leg's time budget covered) and stays unverified, same as the sibling ABI
leg's own honest gap there.

## Known CI condition (not introduced or fixed by this leg)

Same pre-existing wall #124's PR already documented (`spike/abi/FINDINGS.md`):
`suite-linux` (the CI's own x86-64 Linux job) fails `make` itself before any
test runs, because the S0 spike lane a plain `make` always builds
(`spike/context_switch/aarch64_switch.S`) is Apple-arm64-only. This means
CI genuinely cannot reach `spike/runtime/run.sh` on Linux either, same as
it cannot reach `spike/abi/run.sh` there — nothing here fixes or is
responsible for that pre-existing condition. The docker-based verification
above is what substitutes real Linux signal in its place for this leg.

## Deliverables

`spike/runtime/` sources (oracle + leaf externs + four test files),
`docs/defects/m1-3-*.mojo` reproducers, this README, `FINDINGS.md`
(measured results, acceptance-criteria checklist, what's verified where).
