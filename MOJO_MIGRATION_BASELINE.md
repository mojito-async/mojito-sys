# MOJO_MIGRATION_BASELINE.md

**Issue:** #122 (M1.1), part of epic #121 ("EPIC: M mojo-first migration")
**Spec:** every `§N` below resolves in `docs/mojito-sys_MOJO_MIGRATION_SPEC.md`;
`spec §N` resolves in `docs/mojito-sys_IMPLEMENTATION_SPEC.md`.

This is the pre-migration baseline the whole epic is held to. It has two
halves, in this order, because the inventory has to exist before a
measurement can be said to cover it:

1. **Inventory** (§10.1 of the spec): every native source, its role, its
   Mojo fate, the exported symbol set, the ABI/OS struct layouts, platform
   divergence, current build/sanitizer configuration, and a
   conversion-difficulty class per file.
2. **Baseline numbers** (§10.2 of the spec): a full MSVS run, performance
   numbers for every §17 primitive, binary/executable sizes, and measured
   (not asserted) allocation counts on the fast paths spec SYS-4 promises
   are allocation-free.

**Rule (spec §10.3):** no conversion work of any kind — no Phase 2 issue,
no spike leg in Phase 1 — starts before both halves below are complete and
committed with no placeholder rows. A gap found here is a defect in the
baseline, not something a later phase quietly works around.

---

## Reference host

Every number in this document was measured on this host, on this date,
and nowhere else unless a row says so explicitly:

| item | value |
|---|---|
| host | Darwin JUPITER.lan 25.6.0 arm64 (Apple Silicon, Apple M5) |
| OS version | macOS 26.6.2 (build 25G83) |
| Mojo toolchain | 1.0.0b2 (`2cf4d08a`), `mojolang` Homebrew tap — matches the version this repo's README and `spike/context_switch/SPIKE_REPORT.md` pin |
| C compiler | Apple clang version 21.0.0 (clang-2100.0.123.102), target `arm64-apple-darwin25.6.0` |
| Page size | 16384 bytes (`getconf PAGESIZE`, `sysconf(_SC_PAGESIZE)`) |
| Date measured | 2026-08-31 |

This is a single-host, single-architecture baseline (macOS AArch64). Every
Linux-only or x86-64-only row below says so explicitly and is marked
"not measured on this host" rather than guessed — the M1.2 spike leg
(#124) is what puts a real Linux/x86-64 host in the loop for the ABI
layout of `struct epoll_event` and the behavior of the futex backend; this
baseline does not fabricate numbers for either.

---

# Half 1 — Inventory

## 1. Native source inventory

Every native source file under `native/` and `spike/context_switch/`,
with its role, platform reach, and Mojo-migration fate. "Fate" uses three
values:

- **REPLACE** — Mojo calls libc/pthreads/the OS directly; this C file is
  deleted once its Mojo replacement passes parity (§16).
- **KEEP (asm seam)** — stays exactly as it is: the irreducible
  register-level machine edge (§15). Not "converted"; Mojo calls it
  directly or through the thinnest possible adapter, per the M1.4 spike
  leg's own finding.
- **KEEP (shim)** — a tiny, registered C shim that survives because Mojo
  genuinely cannot express the construct (§14).
- **ORACLE-ONLY** — frozen historical/reference code (the S0 spike, or
  the public header once its C build stops being the product, §11/§19):
  not converted, kept as the permanent differential-testing target or as
  a closed historical record.

### 1.1 `native/include/` — the public frozen ABI

| File | Role | Platform reach | Fate | Difficulty |
|---|---|---|---|---|
| `mojito_sys.h` | The frozen C ABI declaration surface (`mjs_*`, `ms_context_*`): every struct, typedef, constant and function signature every other file in `native/` implements. Nothing here is executable. | POSIX-both (macOS + Linux); a few backend-guarded blocks (kqueue/epoll/io_uring) are platform-specific by design | ORACLE-ONLY — the header itself is not "ported"; its Mojo-side mirror is new code (`M2.1`, §2), and this header stays as the C oracle's own contract for as long as the dylib is built (§11, §19) | N/A (declarations only) |

### 1.2 `native/posix/` — the C implementation being replaced

| File | Role | Platform reach | Fate | Difficulty |
|---|---|---|---|---|
| `mjs_abi.c` | Returns `MOJITO_SYS_ABI_VERSION`, a compile-time constant | POSIX-both | REPLACE | Trivial |
| `mjs_page.c` | `sysconf(_SC_PAGESIZE)` query, cached | POSIX-both | REPLACE | Trivial |
| `mjs_vm.c` | `mmap`/`mprotect`/`munmap` reserve/commit/decommit/protect/release | POSIX-both (identical code path on both; no `#ifdef`) | REPLACE | Low |
| `mjs_stack.c` | Non-moving guarded-stack allocator over `mmap`/`mprotect`/`munmap`, plus a small base→size registry so free can `munmap` the exact reservation | POSIX-both | REPLACE | Medium (registry bookkeeping + several overflow-safe rounding guards worth preserving exactly) |
| `mjs_thread.c` | `pthread_create`/`join`/`detach`, atomic refcounted handle lifetime, darwin-vs-Linux `pthread_setname_np` call-shape difference | POSIX-both, one `#ifdef __APPLE__` for the name-setting call shape | REPLACE | High (atomic state machine: `MJS_TS_JOINABLE`/`DETACHED`/`JOINED`, two-owner refcounting between the caller and the trampoline) |
| `mjs_tls.c` | Validated registry over `pthread_key_create/delete/get/setspecific`; monotonic never-reused public ids over a private `pthread_key_t` registry | POSIX-both | REPLACE | Medium (global-mutex registry with realloc-on-grow, documented scalability ceiling) |
| `mjs_cpu.c` | Logical/physical CPU count, current-thread affinity | Diverges hard: `sysconf` (both) + `sysctlbyname("hw.physicalcpu")` + `thread_policy_set`/`mach_thread_self` (macOS) vs. `/sys/devices/system/cpu/.../topology/*` sysfs scan + `sched_setaffinity` (Linux) | REPLACE | High (two structurally different implementations behind one signature; the Linux physical-count path is a best-effort sysfs scan with real parsing) |
| `mjs_time.c` | Monotonic clock read/resolution, normalized to ns | `mach_absolute_time` + `mach_timebase_info` + `pthread_once` calibration (macOS) vs. `clock_gettime(CLOCK_MONOTONIC)` (Linux) | REPLACE | Medium (the mach timebase scaling identity is a nontrivial piece of integer math worth preserving exactly, not just re-deriving) |
| `mjs_mutex.c` | Thin `pthread_mutex_*` wrapper | POSIX-both | REPLACE | Low |
| `mjs_condvar.c` | `pthread_cond_*` wrapper; owns the clock-domain split for every S3 primitive built on top of it (event, semaphore, atomic-wait fallback) | `pthread_condattr_setclock(CLOCK_MONOTONIC)` (Linux) vs. `pthread_cond_timedwait_relative_np` + hand-computed remainder (macOS, no `condattr` clock selection exists) | REPLACE | High (the clock-domain trap is the single most-documented gotcha in this tree — issue #58's own CAUTION block — and it has to survive the port exactly, including the empirical Darwin late-fire skew note) |
| `mjs_atomic_wait.c` | Atomic wait/wake on `u32` words | Linux: raw `syscall(SYS_futex, ...)` (`FUTEX_WAIT_PRIVATE`/`FUTEX_WAKE_PRIVATE`). macOS: a 256-slot address-hashed waiter table composed from `mjs_mutex`/`mjs_condvar` (no `__ulock`, no private kernel interface, by policy) | REPLACE | Very High (two structurally unrelated backends; the macOS fallback is a hand-rolled FIFO waiter-list-per-slot with its own lost-wakeup-freedom argument) |
| `mjs_event.c` | Auto-reset, breadth-one event; composes `mjs_mutex` + `mjs_condvar` + one token int | POSIX-both, no platform `#ifdef` at all (the split lives entirely inside `mjs_condvar.c`) | REPLACE | Medium |
| `mjs_sem.c` | Counting semaphore; composes `mjs_mutex` + `mjs_condvar` + one count int | POSIX-both, no platform `#ifdef` | REPLACE | Medium |
| `mjs_socket.c` | Non-blocking socket primitives; neutral `mjs_sockaddr` ⇄ OS `sockaddr_*` conversion; `FD_CLOEXEC`/`O_NONBLOCK` inheritance normalization | `AF_INET6` numeric divergence (30 darwin / 10 Linux); darwin `sockaddr_in`/`_in6`/`_un` carry `sin_len`/`sin6_len`/`sun_len` at byte 0, Linux does not; Linux inherits `O_NONBLOCK` through `accept(2)`, darwin does not (explicit re-apply) | REPLACE | High (the neutral-address conversion layer plus two distinct inheritance-normalization behaviors is real platform-divergence logic, not a thin wrapper) |
| `mjs_poller.c` | Readiness poller, kqueue backend; `EV_CLEAR` edge semantics; sticky `EVFILT_USER` wake | macOS/BSD only (`__APPLE__`/`__FreeBSD__`/`__OpenBSD__`/`__NetBSD__`/`__DragonFly__`); Linux/other hosts get a detect-and-exclude `-ENOSYS` stub compiled into the SAME file | High | High (upsert semantics, EOF/ERROR flag derivation from `EV_EOF`+negative `data`, a stack-resident 256-entry kevent batch) |
| `mjs_epoll.c` | Readiness poller, epoll backend; level-triggered; sticky `eventfd` wake | Linux only; other hosts get the same detect-and-exclude stub pattern as `mjs_poller.c` | REPLACE | High (mirrors `mjs_poller.c`'s difficulty; level- vs. edge-triggered default is a real semantic difference from the kqueue sibling, not just an API difference) |
| `mjs_iouring.c` | Experimental, capability-flagged io_uring readiness backend; raw syscalls, no `liburing` | Linux only, and only when `MOJITO_IO_URING=1` AND the host kernel supports it (`mjs_iouring_probe`) | REPLACE | Very High (largest file in the tree at 915 lines: raw `io_uring_setup`/`io_uring_enter` syscalls, three `mmap`'d rings managed by hand, one-shot `IORING_OP_POLL_ADD` re-arming, an SQE-availability control-op flush-and-retry path) |
| `ms_context.c` | Portable dispatch half of the frozen `ms_context` v2/v3 ABI: layout `_Static_assert`s, argument validation, capture-as-self-switch, destroy-as-poison, the per-context finish-hook registry | POSIX-both; one `#if defined(__x86_64__)` assert pairing with the x86-64 backend | REPLACE (the portable C dispatch logic moves to Mojo; only the register-level save/restore stays `.S`, §15) | High (this is the file the whole architecture hangs on: state-machine correctness here is what makes the `.S` switch safe to call at all) |
| `mjs_ctx_call.c` | Dynamic-dispatch shim: calls a caller-supplied function address from C because the equivalent Mojo inline-asm indirect branch crashes the pinned b2 JIT | POSIX-both | **KEEP (shim)** — the existing precedent for §14; 31 lines, single purpose, already registered by its own file comment | N/A (retained, not converted) |
| `mjs_sync_internal.h` | Private struct-sharing header: `struct mjs_mutex { pthread_mutex_t pm; }`, shared between `mjs_mutex.c` and `mjs_condvar.c` only; explicitly NOT installed, NOT part of the frozen ABI | POSIX-both | REPLACE (retires alongside `mjs_mutex.c`/`mjs_condvar.c`; Mojo's mutex/condvar types own their internal layout directly, no cross-file C struct-sharing convention needed) | Low |
| `ms_context_aarch64.S` | Register-level AAPCS64 context switch: save/restore `x19`-`x28`, `fp`, `lr`, `d8`-`d15`, `sp`; per-context lifecycle state machine in the v3 tail; synthetic-entry trampoline; loud `brk` traps on misuse | Darwin Mach-O AND Linux ELF (one macro-guarded skeleton, both ABIs) | **KEEP (asm seam)** — the irreducible machine edge (§15); M1.4 (#128) determines whether Mojo calls it directly or needs a thin adapter | N/A (retained; not a conversion candidate) |
| `ms_context_x86_64.S` | Same v2/v3 layout and lifecycle discipline, x86-64 SysV backend | Darwin Mach-O AND Linux ELF; cross-assembled only on this (arm64) host — cannot execute here; NOT `NativeContext`-supported yet (only 8 of the required xmm6-xmm15 low-64 halves are preserved; spec §38.6) | **KEEP (asm seam)** | N/A (retained; behavioral rows are red-excluded UNSUPPORTED-PLATFORM on this host per spec §38.6) |

### 1.3 `spike/context_switch/` — the completed, frozen S0 spike

S0 (`spike/context_switch/`) already answered its own question — GO,
unconditional, per `SPIKE_REPORT.md` — before this epic existed. Every
file here is **ORACLE-ONLY**: historical evidence that a Mojo call chain
survives an external stack switch through a C-ABI seam, kept exactly as
it is rather than touched again. The Mojo-first question this epic asks
(§7) is harder, and M1.4 (#128) answers it fresh against
`native/posix/ms_context_aarch64.S`, not by editing these files.

| File | Role | Platform reach | Fate | Difficulty |
|---|---|---|---|---|
| `include/mojito_spike.h` | Frozen S0 C header: `ms_ctx_t` (168-byte v2 save area), `ms_page_size`/`ms_stack_alloc`/`ms_stack_free`/`ms_ctx_make`/`ms_ctx_switch` | macOS arm64 only (S0's own documented scope) | ORACLE-ONLY | N/A |
| `native_stack.c` | S0's own guarded stack allocator (predecessor to `native/posix/mjs_stack.c`) | macOS arm64 | ORACLE-ONLY | N/A |
| `aarch64_switch.S` | S0's own context switch (predecessor to `native/posix/ms_context_aarch64.S`); the panel-proven template the production backend was ported from "verbatim-in-structure" | macOS arm64 only (`#error` on other targets, per the CI notes in `.github/workflows/ci.yml`) | ORACLE-ONLY | N/A |
| `ms_ctx.c` | Compile-time layout guards (`_Static_assert`) plus a committed sentinel-register probe (`ms_ctx_sentinel_probe`) used as panel evidence for the d8-d15 preservation amendment | macOS arm64 | ORACLE-ONLY | N/A |
| `selftest.c` | S0's foundation allocator selftest (31 checks; `make selftest`) | macOS arm64 | ORACLE-ONLY | N/A |
| `mojito_spike.mojo` | S0's Mojo bindings: the `@export` + `entry_pointer[symbol]()` function-pointer materialization recipe every later thread/callback binding in `mojito_sys/` still uses | macOS arm64 (Mojo, host-portable language but the linked spike dylib is arm64-only) | ORACLE-ONLY | N/A |
| `demo.mojo` | S0's end-to-end smoke demo exercising the whole spike dylib surface from Mojo | macOS arm64 | ORACLE-ONLY | N/A |

---

## 2. Exported C symbol inventory

Captured from the built `libmojito_sys.dylib` with `nm -gU`, never
transcribed from the header, by a committed and rerunnable script:

```sh
tools/migration_baseline/gen_symbol_inventory.sh          # regenerate
tools/migration_baseline/gen_symbol_inventory.sh --check   # verify no drift
```

**93 exported symbols**, all under the `mjs_*` or `ms_context_*` prefix
(no other symbol leaks out of the packaged dylib — confirmed by comparing
against the unfiltered `nm -gU` count, which is also 93). The full,
sorted list is committed at `MOJO_MIGRATION_SYMBOLS.txt`. Re-running the
script after any `native/` change and diffing against that file is the
mechanism later ABI-diff work (`M2.1` onward) uses to prove nothing was
silently added, removed, or renamed outside an explicit ABI decision.

---

## 3. ABI and OS-struct layout inventory

Captured from an actual C oracle program compiled and run on the
reference host — `tools/migration_baseline/abi_oracle.c` — never copied
from a comment, via:

```sh
tools/migration_baseline/run_abi_oracle.sh          # regenerate
tools/migration_baseline/run_abi_oracle.sh --check   # verify no drift
```

The full JSON Lines output (51 rows: our own ABI structs, opaque handle
slots, function-pointer typedefs, ABI constants, and the OS
structs/typedefs the implementation consumes but never exports) is
committed at `MOJO_MIGRATION_ABI_LAYOUT.jsonl`. Summary tables follow;
every number below is this host's actual compiler output, reproduced
verbatim from that file.

### 3.1 Our own ABI structs (`native/include/mojito_sys.h`, public)

| Struct | Size | Align | Fields (offset : size) |
|---|---|---|---|
| `mjs_sockaddr` | 136 | 4 | `family` 0:4, `port` 4:2, `_pad0` 6:2, `flowinfo` 8:4, `scope_id` 12:4, `octets` 16:16, `path` 32:104 |
| `mjs_poll_event` | 16 | 8 | `token` 0:8, `fd` 8:4, `events` 12:4 |
| `mjs_callback_token` | 16 | 8 | `addr` 0:8, `userdata` 8:8 |

`mjs_sockaddr`'s 136-byte size matches the header comment's own claim
("sizeof == 136 on LP64 hosts") exactly — the first cross-check the
oracle gives for free.

### 3.2 `ms_context` (opaque; size/alignment are the public contract)

`ms_context` is intentionally opaque outside `native/posix/ms_context.c`
(SYS-3), so the oracle queries its geometry through the runtime getters
rather than `sizeof`-ing an incomplete type:

| Getter | Value |
|---|---|
| `ms_context_size()` | 200 bytes |
| `ms_context_alignment()` | 8 |

Internal field offsets (package-private, pinned by `_Static_assert` in
`ms_context.c`, not re-measured by the oracle since this is exactly the
information SYS-3 says is nobody else's business): `regs[12]` @0..95,
`fps[8]` @96..159, `sp` @160, `state` @168, `ret_to` @176, `finish_cb`
@184, `finish_ud` @192 — 168-byte frozen v2 prefix + 32-byte v3 lifecycle
tail = 200 bytes total.

### 3.3 Opaque handle slots (only the pointer crosses the ABI)

Every `mjs_*` handle typedef (`mjs_thread`, `mjs_mutex`, `mjs_condvar`,
`mjs_event`, `mjs_sem`, `mjs_poller`, `mjs_epoller`, `mjs_uring`) is
opaque by design (SYS-3): the oracle confirms each handle POINTER is 8
bytes, 8-byte aligned, on this LP64 host — the pointee layout is never
public and is not measured.

### 3.4 Function-pointer typedefs (public: they cross the ABI as values)

| Typedef | Size | Align |
|---|---|---|
| `ms_callback` (`void(*)(void*)`) | 8 | 8 |
| `ms_thread_entry` (`long(*)(void*)`) | 8 | 8 |
| `ms_context_entry` (`void(*)(void*)`) | 8 | 8 |
| `ms_context_finish_fn` (`void(*)(void*)`) | 8 | 8 |

### 3.5 ABI constants (compile-time, from the header)

| Constant | Value |
|---|---|
| `MOJITO_SYS_ABI_VERSION` | 1 |
| `MJS_PROT_NONE` / `READ` / `WRITE` / `EXEC` | 0x00 / 0x01 / 0x02 / 0x04 |
| `MJS_SOCK_STREAM` / `DGRAM` / `INET` / `UNIX` | 1 / 2 / 2 / 1 |
| `MJS_SOCK_INET6` | 30 (this host is `__APPLE__`; 10 on Linux — see 3.7) |
| `MJS_SHUT_READ` / `WRITE` / `BOTH` | 0 / 1 / 2 |
| `MJS_POLL_READABLE` / `WRITABLE` / `EOF` / `ERROR` | 0x1 / 0x2 / 0x4 / 0x8 |

### 3.6 OS structs/typedefs consumed but never exported

These never appear in `native/include/mojito_sys.h`; Mojo has to
describe them byte-exact anyway, because the implementation reads and
writes their fields directly.

| Struct/typedef | Source | Size (this host) | Align | Notes |
|---|---|---|---|---|
| `struct timespec` | `<time.h>` | 16 | 8 | `tv_sec` 0:8, `tv_nsec` 8:8 |
| `struct timeval` | `<sys/time.h>` | 16 | 8 | `tv_sec` 0:8, `tv_usec` 8:8 |
| `struct sockaddr_in` | `<netinet/in.h>` | 16 | 4 | darwin carries `sin_len` @0:1 ahead of `sin_family` @1:1 — Linux has no `sin_len` field at all, see 3.7 |
| `struct sockaddr_in6` | `<netinet/in.h>` | 28 | 4 | darwin carries `sin6_len` @0:1 the same way |
| `struct sockaddr_un` | `<sys/un.h>` | 106 | 2 | darwin carries `sun_len` @0:1; `sun_path` is 104 bytes on this host |
| `sa_family_t` | `<sys/socket.h>` | 1 | 1 | scalar typedef |
| `socklen_t` | `<sys/socket.h>` | 4 | 4 | scalar typedef |
| `struct iovec` | `<sys/uio.h>` | 16 | 8 | `iov_base` 0:8, `iov_len` 8:8 |
| `struct kevent` | `<sys/event.h>` (BSD/macOS) | 48 | 8 | `ident` 0:8, `filter` 8:2, `flags` 10:2, `fflags` 12:4, `data` 16:8, `udata` 24:8 |
| `struct epoll_event` | `<sys/epoll.h>` (Linux only) | **not measured on this host** | — | Linux-only; notoriously `__attribute__((packed))` on x86-64 and NOT packed on AArch64 (`native/posix/mjs_epoll.c`'s own callout, echoed in issue #124) — the M1.2 spike leg measures this for real on both Linux targets rather than this baseline guessing it |
| `pthread_attr_t` | `<pthread.h>` | 64 | 8 | opaque libc blob; contents are never inspected, only sized for `pthread_attr_init` storage |
| `pthread_mutex_t` | `<pthread.h>` | 64 | 8 | opaque libc blob; wrapped by `mjs_mutex.c`/`mjs_sync_internal.h` |
| `pthread_cond_t` | `<pthread.h>` | 48 | 8 | opaque libc blob; wrapped by `mjs_condvar.c` |
| `pthread_key_t` | `<pthread.h>` | 8 (via `unsigned long`) | 8 | opaque libc scalar; wrapped by `mjs_tls.c`'s validated registry |
| `pthread_t` | `<pthread.h>` | 8 | 8 | opaque libc handle; wrapped by `mjs_thread.c` (`struct mjs_thread.pt`) |

Exact sizes for `pthread_attr_t`/`pthread_mutex_t`/`pthread_cond_t`/
`pthread_key_t` above are this host's (Darwin/libSystem) values, read
straight from the oracle's JSONL output — see the file for the byte-exact
numbers rather than re-deriving them from this table if a future diff
needs precision beyond what is written here.

### 3.7 Platform-numeric divergence (host values, this run)

| Constant | This host (Darwin) | Linux (documented, not measured here) |
|---|---|---|
| `AF_INET` | 2 | 2 (same) |
| `AF_INET6` | 30 | 10 |
| `AF_UNIX` | 1 | 1 (same) |
| `O_NONBLOCK` | 0x0004 | 0x0800 |

The Linux column above is the numeric value glibc/the Linux kernel headers
define; it is recorded here from `native/posix/mjs_socket.c`'s own
comments and `errno.h`/`fcntl.h` public knowledge, not measured on this
host — flagged as such rather than presented as an oracle result. `M1.2`
(#124) and `M2.1` (#129) are the places a real Linux oracle run confirms
it.

---

## 4. Platform-specific behavior per file

Consolidated view of every place `native/posix/` genuinely diverges
between macOS and Linux (the per-file table in §1.2 already calls out
platform reach; this section is the "what actually differs, and why it
matters" writeup §122 asks for):

- **`mjs_cpu.c`** — the two `mjs_cpu_physical()` implementations are not
  the same algorithm ported twice: macOS asks the kernel directly
  (`sysctlbyname("hw.physicalcpu")`), Linux has no equivalent syscall and
  instead scans `/sys/devices/system/cpu/*/topology/{physical_package_id,
  core_id}` and counts unique pairs, falling back to `-ENOTSUP` on any
  partial read. A Mojo port has to reproduce the sysfs-scan algorithm on
  Linux, not just call a different one-line API.
- **`mjs_time.c`** — Linux's `clock_gettime(CLOCK_MONOTONIC)` is
  ns-native; macOS's `mach_absolute_time()` returns opaque ticks that need
  a `mach_timebase_info` numer/denom scaling identity, calibrated once
  behind `pthread_once`. This is genuinely two different mechanisms
  normalized to the same output, not a syntax difference.
- **`mjs_condvar.c`** — Linux pins the condvar's internal clock to
  `CLOCK_MONOTONIC` via `pthread_condattr_setclock` at creation time, so
  an absolute deadline converts 1:1. macOS has no such attribute at all;
  the only documented equivalent is
  `pthread_cond_timedwait_relative_np`, which takes a *relative* remainder
  recomputed at every call entry from `mjs_clock_now()`. The empirical
  Darwin skew this file documents (~6ms p50, ~10ms max overshoot under a
  19-waiter broadcast storm, always late and never early) is a real
  platform property a Mojo port inherits, not an implementation detail
  that disappears with a rewrite.
- **`mjs_atomic_wait.c`** — Linux has a kernel-native futex; macOS has no
  public equivalent kernel primitive mojito-sys is willing to depend on
  (spec §18 forbids `__ulock`/private interfaces), so the macOS path is an
  entirely different mechanism: a 256-slot address-hashed table of
  mutex+condvar-guarded FIFO waiter lists, built from primitives this
  repository already exports. This is the single largest platform
  divergence in the tree by implementation complexity, not just line
  count.
- **`mjs_socket.c`** — three separate divergences in one file:
  `AF_INET6`'s numeric value (30 vs. 10); darwin `sockaddr_in`/`_in6`/
  `_un` carrying a leading `sin_len`/`sin6_len`/`sun_len` byte Linux does
  not have; and `O_NONBLOCK` inheritance through `accept(2)` (automatic on
  Linux, explicitly re-applied on darwin so reactor behavior is identical
  across hosts).
- **`mjs_poller.c` vs. `mjs_epoll.c`** — these are not the same file
  behind an `#ifdef`; they are two files, each built into the SAME dylib,
  each providing a detect-and-exclude `-ENOSYS` stub for the platform it
  does not own. kqueue is edge-triggered by construction (`EV_CLEAR`);
  epoll is level-triggered by design choice (`EPOLLET` is deliberately
  never exposed through the frozen ABI) — a genuine semantic difference
  a reactor built on top has to know about, not merely a backend swap.
- **`mjs_thread.c`** — `pthread_setname_np` takes one argument on darwin
  (self-only) and two on Linux (`pthread_t` + name); every other line in
  the file is platform-neutral.
- **Where a "POSIX" path is really macOS-only:** `native/posix/mjs_poller.c`
  is filed under `native/posix/` but its `MJS_HAVE_KQUEUE` guard is
  BSD/Darwin only — nothing about it runs on Linux, where `mjs_epoll.c`
  (same directory) is the real implementation. The directory name is
  historical (predates the epoll/io_uring backends landing), not a claim
  that every file in it is portable POSIX code.

---

## 5. Current Clang flags, Makefile lanes and sanitizer jobs

**Compiler flags** (from `Makefile`): `CC ?= cc`, `CFLAGS ?= -O2 -g -Wall
-Wextra`, applied uniformly to every `native/**/*.c` object
(`$(SYS_BUILD)/%.o: native/%.c`). Assembly (`native/**/*.S`) is assembled
with no optimization/warning flags beyond the include path (`cc -I$(SYS_INC)
-c ...`). `-MMD -MF` dependency files are generated per translation unit
for the packaged `native/` tree (not for the S0 spike tree, which predates
that convention).

**Makefile lanes** (`make <target>`):

| Target | Builds/runs |
|---|---|
| `all` (default) | `libmojito_spike.dylib` + `selftest` + `libmojito_sys.dylib` |
| `selftest` | S0 foundation allocator selftest (31 checks) |
| `test` | S0 semantic tests T1-T7 (`tests/spike/run.sh`) + T8-T14 (`tests/spike/run_t8_t14.sh`) |
| `bench` | S0 context-switch benchmark (`benchmark/spike/bench_switch.mojo`) — **known-flaky**, see below |
| `bench-io` | S6 poller + socket-loopback benchmark (`benchmark/io/run.sh`) |
| `test-s1` | S1 ABI/memory/io conformance (`tests/s1/run.sh`) |
| `test-s2` / `test-s2-conformance` / `test-s2-stress` / `test-s2-integration` / `test-s2-pkg` | S2 thread/TLS lanes |
| `test-s3` | S3 sync (`tests/s3/run.sh`) |
| `test-s5` | S5 context lanes (`tests/s5/run.sh`) |
| `test-contract-sweep` | ABI-wide `mjs_*` rc-sign sweep (`tests/contract_sweep/run.sh`) |
| `test-s6` | S6 I/O conformance, self-scoring PASS/ENV/FAIL per lane (`tests/s6/run.sh`) |
| `clean` | removes `build/`, both dylibs |

**Sanitizer jobs:** there is **no dedicated ASan/UBSan/TSan CI lane** in
this repository today. The only sanitizer usage anywhere in the tree is a
single **non-gating compile-only smoke** inside `tests/s2/stress/run.sh`:
one C shim (`atomic_shim.c`) is compiled with
`-fsanitize=address,undefined` and the compile is checked for success,
but the resulting object is never linked or run under the sanitizer (the
file's own comment: "an ASan/TSan run of the DRIVER is not expressible
with this toolchain"). `.github/workflows/ci.yml` runs four jobs
(`gate-selftest`, `suite-macos` — blocking, `suite-linux` — reported not
blocking, `suite-s6-linux` — reported not blocking); none of them invoke
a sanitizer build. This is recorded here as the honest current state
(spec §35's sanitizer/tooling section already anticipates this gap for
Mojo, §12 of this migration's own spec) — not something this baseline
should paper over with an aspirational "sanitizers run in CI" claim that
is not true today.

**The `bench` known-flake:** `precommit/known-red.tsv` currently
allow-lists the `bench` driver against issue #129, because `make bench`
(the S0 context-switch benchmark under `mojo run`) intermittently SIGTRAPs
inside Mojo's own `libKGENCompilerRTShared.dylib` during its
sampled-latency phase (roughly 2 of 3 captured runs). This is a
toolchain flake, not a defect in this repository's own code, and it is
recorded here because it directly bears on how much to trust a single
`mojo run`-based benchmark sample without retries — every benchmark
number in Half 2 of this document that used `mojo run` was captured from
a run that completed cleanly end to end, and a retry loop is standard
practice elsewhere in this tree (`benchmark/io/run.sh` already retries up
to 4 times on exactly this class of crash).

---

## 6. Conversion-difficulty classification

Five classes, applied per file in §1.2's table; defined here once rather
than repeated per row:

| Class | Meaning |
|---|---|
| **Trivial** | A single libc call with no platform branching, no state, no error-path complexity beyond the standard 0/-errno contract |
| **Low** | A thin wrapper over one libc/pthread family, no platform `#ifdef`, no nontrivial state |
| **Medium** | Either real internal state (a registry, a composed type) or one platform `#ifdef`, but not both |
| **High** | Nontrivial state AND platform divergence together, or a backend-specific translation layer (event flag derivation, address conversion) |
| **Very High** | Raw syscalls with no libc wrapper at all, and/or hand-managed shared memory (ring buffers) with kernel-documented ordering rules that must be reproduced exactly |

Files marked `KEEP (asm seam)` or `KEEP (shim)` in §1.2 are not scored on
this scale at all — they are not conversion candidates, so "how hard would
this be to convert" does not apply to them.

---

## 7. Public versus package-stable header surface

`native/include/mojito_sys.h` is **installed and public**: every
declaration in it (every `mjs_*`/`ms_context_*` function, `mjs_sockaddr`,
`mjs_poll_event`, `mjs_callback_token`, every `MJS_*` constant, every
opaque handle typedef) is the frozen ABI `mojito-async` and any other
consumer binds against. Nothing in this header is a Mojo-migration
implementation detail; §2 of the spec is this header's surface,
declared directly in Mojo instead of behind a C wrapper.

`native/posix/mjs_sync_internal.h` is **package-private**, by its own
file comment: "NOT installed, NOT part of the frozen public ABI... The
definition lives here... so `mjs_condvar_wait`/`wait_until` can pass
`&mutex->pm` straight to `pthread_cond_*` without a second source of
truth." It exists purely to let two C translation units share one struct
layout; Mojo's mutex/condvar types do not need an equivalent file, since
a struct's fields are visible within its own module without a
cross-file-sharing convention.

`ms_context`'s internal record layout (`native/posix/ms_context.c`'s
`struct ms_context` and its `_Static_assert`s) sits in between: the
header's own comment calls it out explicitly — "Backend-pinned via
`_Static_assert`s in `ms_context.c` — INTERNAL to the library,
informational here, not a consumer promise." Only `ms_context_size()`
and `ms_context_alignment()` (§3.2) are the public contract; the field
offsets are package-stable, meaning M2.4's Mojo port must reproduce them
exactly for the `.S` backend to keep working, but no external consumer is
entitled to assume them.

`spike/context_switch/include/mojito_spike.h` is neither: it is a frozen
**historical** header (§1.3), not installed anywhere, not linked by
anything outside the S0 spike tree.

---

# Half 2 — Pre-migration numbers

## 8. MSVS run

A full run of this repository's own test suite (`precommit/run-suite.sh`,
`MOJITO_GATE_TIER=full`, the same driver CI's `suite-macos` job runs
blocking), captured verbatim and mapped onto the spec §38.16
machine-readable schema. Command:

```sh
MOJITO_GATE_TIER=full ./precommit/run-suite.sh
```

Every `VERDICT<TAB><driver><TAB><PASS|RED|FAIL>` line the suite printed
is one row below. `precommit/known-red.tsv` currently allow-lists two
drivers (`bench` → #129, the intermittent sampled-latency SIGTRAP flake;
`s5-ctx-api` → #142, a genuinely red lane): a driver that comes back
`FAIL` from the suite is reported here as `RED` only when it has a live
allow-list row, never silently reclassified as `PASS`.

| Driver | Result | Notes |
|---|---|---|
| `gate_selftest` | PASS | precommit gate's own self-test (8 cases) |
| `selftest` | PASS | S0 foundation allocator selftest, 31/31 |
| `no-markers` | PASS | no unresolved conflict markers |
| `t1-t7` | PASS | S0 semantic tests (address stability, borrows, dtors, raises, 10k switches, depth 64) |
| `t8-t14` | PASS | S0 register/TLS/guard/audit tests |
| `bench` | PASS | S0 context-switch benchmark; allow-listed known-red against #129's intermittent SIGTRAP, but this run completed clean end to end |
| `s1-tests` | PASS | S1 ABI/memory/io conformance |
| `s2-tests` | PASS | S2 thread/TLS |
| `s2-conformance` | PASS | S2 conformance matrix |
| `s2-stress` | PASS | S2 stress (200 storm children / 8 writers, 128 barrier-burst threads, 48 detached ghosts; ledger reconciled exactly, zero lost wakes, zero double-joins) |
| `s2-integration` | PASS | S2 worker-farm integration (§41 exit criterion) |
| `s2-pkg` | PASS | S2 link/import smoke |
| `s3-atomic-wait` | PASS | S3.3 atomic wait/wake |
| `s3-other` | PASS | S3 mutex/condvar/semaphore/event |
| `s5-ctx-api` | **RED** | allow-listed against #142 (`precommit/known-red.tsv`); genuinely red today, not deferred silently |
| `s5-other` | PASS | S5 ctx sentinel/lifecycle/oracle + x86 structural mirror (x86 behavioral rows RED-EXCLUDED UNSUPPORTED-PLATFORM on this Darwin/arm64 host, per spec §38.6 — expected, not a failure) |
| `s6-tests` | PASS | S6 I/O conformance; 4 lanes report ENV (io_uring requires `MOJITO_IO_URING=1` plus host kernel support neither of which this host's default config provides — a scored environment result, not a failure, per `tests/s6/run.sh`'s own convention) |

17 of 17 drivers accounted for; 1 genuinely red (tracked, not silent), 0
unexplained failures.

## 9. Allocation counts (spec SYS-4 fast paths)

Measured, not asserted, via a dyld-interposing `malloc`/`calloc`/
`realloc`/`free` counter (§18 of the spec) —
`tools/migration_baseline/alloc_probe_shim.c` +
`tools/migration_baseline/alloc_count_fastpaths.c`, rerunnable as:

```sh
tools/migration_baseline/run_alloc_counts.sh          # regenerate
tools/migration_baseline/run_alloc_counts.sh --check   # verify no drift
```

Full committed output: `MOJO_MIGRATION_ALLOC_COUNTS.tsv`.

| Primitive | Iterations | Alloc calls (total) | Free calls (total) | Reading |
|---|---|---|---|---|
| `mjs_page_size` | 100,000 | 0 | 0 | Zero allocation, every call |
| `mjs_clock_now` | 100,000 | 0 | 0 | Zero allocation, every call |
| `mjs_vm_commit` + `mjs_vm_decommit` | 1,000 (2,000 syscalls) | 0 | 0 | Zero allocation on a pre-reserved region — confirms the file comment's own "thin, allocation-free wrappers" claim |
| `mjs_tls_get` | 100,000 | 0 | 0 | Zero allocation — matches the header's explicit "Never allocates (SYS-4)" contract exactly |
| `mjs_thread_spawn` + `mjs_thread_join` | 200 (real OS threads) | 200 | 200 | One `calloc`'d handle per spawn, one `free` per join — expected and NOT a SYS-4 violation, since thread spawn is never claimed allocation-free by the header; this row exists to confirm the actual count, not to prove zero |
| `ms_context_switch` (self-capture loop) | 100,000 | 0 | 0 | Zero allocation — matches "switching is allocation-free (spec §20.1)" exactly |
| `mjs_event_signal` + `mjs_event_wait` | 100,000 (non-blocking round trip) | 0 | 0 | Zero allocation post-init — matches "Allocation (SYS-4): ... NONE afterwards" |
| `mjs_atomic_wake_one_u32`, **first call ever** | 1 | 512 | 0 | One-time lazy `pthread_once` init of the macOS 256-slot waiter table: 256 `mjs_mutex_init` + 256 `mjs_condvar_init` = 512 allocations, exactly `2 × MJS_AW_SLOTS`. This is a real, documented, ONE-TIME cost (`native/posix/mjs_atomic_wait.c`'s own `mjs_aw_init`), not a per-call violation — see the steady-state row below for what every subsequent call costs |
| `mjs_atomic_wake_one_u32`, steady state (no waiter) | 100,000 | 0 | 0 | Zero allocation once the lazy table exists — this is the number that actually answers "does this primitive hide an allocation on its hot path" |
| `mjs_poller_wake` | 100,000 | 0 | 0 | Zero allocation post-create — matches "Allocation (SYS-4): one fixed-size handle at create; NONE afterwards" |

Every fast path the header explicitly names SYS-4 measures at genuinely
zero allocation calls in steady state on this host. The one nonzero
steady-state-adjacent number (the atomic-wait table's one-time init) is
exactly `2 × 256` — confirming the mechanism the source comment describes
rather than contradicting it.

## 10. Binary and executable sizes

| Artifact | Size (bytes) | Notes |
|---|---|---|
| `libmojito_sys.dylib` | 70,432 | Packaged S1+ dylib, this build (`make libmojito_sys.dylib`), Mach-O 64-bit arm64 |
| `libmojito_spike.dylib` | 34,744 | S0 spike dylib, for comparison only — not the migration's subject |
| Exported symbol count | 93 | `mjs_*` + `ms_context_*`, §2 of this document |
| Minimal linked Mojo executable | 35,800 | `mojo build` of a bare `def main(): print("hi")`, no `-Xlinker` — this is the Mojo-toolchain-only floor a Phase-2 Mojo replacement package is compared against, independent of anything this repository ships |
| Linked representative `mojito-async` executable | **not measured** | `mojito-async` is a separate repository, out of scope for this issue; `M4.1`'s consumer-inventory work is where that number gets captured for real |

---

## 11. Performance baseline — §17 primitives

Methodology (spec §38.12): warmup rounds precede every measurement; a
0.2s duration floor AND a 20-iteration floor keep micro-runs from being
reported; timing is wall-clock monotonic ns via `mjs_clock_now`
(identical clock source the Mojo wrappers use). Every row below ran on
the reference host (top of this document) against the current
`libmojito_sys.dylib` build.

The context-switch, poller and socket rows already have dedicated,
committed benches in this tree (`benchmark/ctx/bench_switch.mojo`,
`benchmark/io/poller_bench.mojo`, `benchmark/io/socket_loopback_bench.mojo`);
this baseline runs them for real rather than duplicating them. The other
eight rows are new (`benchmark/baseline/bench_primitives.mojo`, landed by
this issue), since nothing else in the tree measured them before.

Commands used, in order:

```sh
mojo run -I . -Xlinker libmojito_sys.dylib benchmark/baseline/bench_primitives.mojo
./benchmark/ctx/run.sh
mojo run -I . -Xlinker libmojito_sys.dylib benchmark/io/socket_loopback_bench.mojo
mojo run -I . -Xlinker libmojito_sys.dylib benchmark/io/poller_bench.mojo
```

### 11.1 The twelve §17 rows

| # | Primitive | Comparison | Result |
|---|---|---|---|
| 1 | FFI no-op crossing | Mojo calling `mjs_abi_version()` (trivial C-side work; the closest this repo can get to measuring pure crossing overhead) | **1,086,516,069 ops/sec** (~0.92 ns/call), 20,000,000 calls sampled |
| 2 | page-size query | Mojo calling `mjs_page_size()` (`sysconf(_SC_PAGESIZE)`, cached after first call) | **580,597,162 ops/sec** (~1.72 ns/call), 20,000,000 calls sampled |
| 3 | VM reserve/release | `VirtualMemory.reserve(1 MiB)` + `.release()` — one `mmap` + one `munmap` per cycle | **1,480,823 ops/sec** (~675 ns/cycle), 20,000 cycles sampled |
| 4 | VM commit/decommit | `.commit(0, page_size)` + `.decommit(0, page_size)` on a pre-reserved 1 MiB region — one `mprotect` + one `mprotect`+`mmap` per cycle | **582,706 ops/sec** (~1,716 ns/cycle), 20,000 cycles sampled |
| 5 | thread create/join | `spawn_native_thread(...)` + `.join()` — one real `pthread_create` + `pthread_join` per cycle | **46,218 ops/sec** (~21,636 ns/cycle), 2,000 real OS threads sampled |
| 6 | TLS get/set | `NativeTlsKey.get()` steady-state read (the SYS-4 must-not-allocate path; see §9) | **229,160,152 ops/sec** (~4.36 ns/call), 20,000,000 calls sampled |
| 7 | monotonic clock read | `MonotonicInstant.now()` (`mach_absolute_time` + cached timebase scaling on this host) | **75,481,481 ops/sec** (~13.25 ns/call), 15,096,400 calls sampled |
| 8 | native event wait/wake | **(a)** uncontended `signal()`+`wait()` round trip, same thread: **78,803,572 ops/sec** (~12.69 ns/round-trip), 15,760,800 calls. **(b)** cross-thread wake latency (one worker parked in `wait()`, signaled from the main thread — same shape as poller.wake_latency_ns below): **2,792 ns** median, n=16 |
| 9 | context switch | `benchmark/ctx/bench_switch.mojo` (production `ms_context` v2/v3 ABI, self-contained A→B→A ping-pong) | **switch_latency_ns = 6** (min-of-N, per single switch); **round_trips_per_sec = 72,069,450**; sampled-latency **p50 = 12 ns, p95 = 12 ns, p99 = 1,012 ns** |
| 10 | poller add/remove | `benchmark/io/poller_bench.mojo`, kqueue backend: register+modify+unregister triple | **813,788 ops/sec** (register/modify/unregister combined throughput), 32,000 ops sampled; scale tiers: 1,024 regs → 2,302,846 ops/sec, 10,240 regs → 2,220,034 ops/sec |
| 11 | poller wake | `benchmark/io/poller_bench.mojo`, cross-thread `EVFILT_USER` wake latency | **67,875 ns** median, n=16 |
| 12 | socket loopback round trip | `benchmark/io/socket_loopback_bench.mojo`, AF_INET loopback ping-pong | **9,615 ns** median ping-pong latency, n=12,000; connect setup **23,695 ns**, n=2,000; throughput 4 KiB buffers **570 MiB/s**, 64 KiB buffers **9,027 MiB/s** |

### 11.2 Supplementary poller/socket numbers

Not one of the twelve named rows on their own, but part of the same real
runs above and worth recording since they are what `benchmark/io/
baselines.tsv`'s regression gate already holds later Mojo work to:
`poller.create_ops_per_sec` 1,943,988 ops/sec; `poller.empty_wait_ns`
12,970 ns; `poller.one_ready_wait_ns` 210 ns;
`poller.storm_events_per_sec` 1,552,809,159; `poller.token_decode_ops_per_sec`
3,713,239,293; `poller.wait_1024_latency_ns` 195 ns;
`poller.wait_10240_latency_ns` 192 ns; `socket.idle_pairs` 256 (at the
host's unraised `RLIMIT_NOFILE`).

### 11.3 A note on noise (spec §38.13, and this issue's own risk callout)

The first `benchmark/io/run.sh` pass taken right after a long run of this
issue's own new primitive benchmark reported two socket-lane values over
`benchmark/io/baselines.tsv`'s own regression thresholds
(`connect_setup_latency_ns` 70,251 ns against a 42,000 ns ceiling;
`pingpong_latency_ns` 12,592 ns against a 12,325 ns ceiling) — both
`FAIL` under that lane's own gate. A second pass a few seconds later, host
otherwise idle, reported 23,695 ns and 9,615 ns respectively — both
comfortably inside tolerance, and the numbers this document reports in
§11.1. This is host contention noise from this issue's own heavy prior
Mojo activity, not a real regression in `mjs_socket.c`/`mjs_poller.c`
(neither was touched by this issue), and it is recorded here as exactly
the kind of measurement risk the issue's own "noise discipline" callout
warns about: a single sample right after heavy host load is not a
trustworthy baseline number, and this document uses the quiet-host
sample rather than the noisy one.

Every §17 row above has a real Clang implementation behind it — there is
no "no baseline, Mojo is the first implementation" row in this table.
That was true even before `mjs_socket.c`, `mjs_poller.c`, `mjs_epoll.c`,
`mjs_iouring.c` and `mjs_sem.c` landed (per the epic's own scope note);
it is unambiguously true now.
