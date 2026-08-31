# M1.3 runtime spike — findings

Measured results against issue #126's acceptance criteria. Everything
below is a real, dynamically-verified result on macOS arm64 (Darwin
25.6.0, Mojo 1.0.0b2 2cf4d08a, homebrew mojolang tap) AND, where marked,
on native Linux/AArch64 via a local Docker container (Docker Desktop's
own `linux/arm64` engine — genuinely native on this arm64 host, not
QEMU/Rosetta emulation), running the identical `mojo-compiler-1.0.0b2`
build. Re-run: `cd spike/runtime && ./run.sh` (macOS/kqueue half); see
README.md's "Linux verification" section for the exact docker recipe
that produced the Linux rows.

**CI status:** not yet confirmed green on `suite-macos`, the repo's
blocking CI lane -- this PR is pushed and CI-pending at the time this
document was written (see the PR description for the current status).
`suite-linux` cannot reach this leg at all -- same pre-existing condition
#124's PR already documented (see README.md's "Known CI condition"): a
plain `make` fails before any test runs there, because the S0 spike lane
it also builds (`spike/context_switch/aarch64_switch.S`) is Apple-arm64
Mach-O-only. The docker-based recipe in README.md substitutes real Linux
signal for that gap, and is what every Linux row below is backed by.

## Thread half (issue #126)

Acceptance: "a Mojo `abi("C")` entry runs on a `pthread_create` thread on
macOS and Linux, with argument and result round trip verified and clean
join; Mojo value construction and destruction on the spawned thread
behave identically to the main thread, or the difference is documented;
an entry that raises is contained and reported without unwinding into C;
TLS create/set/get/destroy works from Mojo with the exit destructor
firing; `mjs_tls_get`-equivalent reads allocate nothing, measured rather
than asserted."

| Check | macOS arm64 | Linux AArch64 (docker) |
|---|---|---|
| `abi("C")` entry IS the literal `pthread_create` start routine (no C trampoline) | PASS | PASS |
| Argument pointer arrives intact; mutations through it survive | PASS | PASS |
| Entry return value survives `pthread_join` exactly (independent of the arg mutation) | PASS | PASS |
| Clean join, 50 sequential spawn/join cycles (leak-clean smoke) | PASS | PASS |
| `pthread_self()` differs spawned-vs-main, stable within a thread | PASS | PASS |
| `__del__` fires on the spawned thread, ctor/dtor balance == 0 | PASS | PASS |
| `__deinit__` does NOT fire on scope exit (spawned thread OR main) | PASS (parity, see note below) | PASS (parity) |
| Entry-internal raise contained: caught, reported via return value, cleanup still balanced, process stays alive | PASS | PASS |
| `abi("C") raises` rejected at PARSE time (verified directly, not assumed) | PASS (confirmed as a compiler error) | not re-verified on Linux (parser behavior, expected identical; not re-run there) |

**`__deinit__` note**: this is NOT a new defect. `mojito_sys/ctx/context.mojo`
already documents, for the MAIN thread, "b2 1.0.0b2 does not invoke
`__deinit__` on locals." This leg's `thread_test.mojo` T4 confirms the
identical non-firing behavior on a SPAWNED pthread thread too -- exact
parity, which is the acceptance criterion's own "or the difference is
documented" branch. `__del__` (a distinct dunder from `__deinit__` in this
toolchain) is this repo's actual WORKING release hook
(`mojito_sys/io/socket.mojo`, `io/handle.mojo` both use it), and it fires
correctly and identically on both threads.

## TLS

| Check | macOS arm64 | Linux AArch64 (docker) |
|---|---|---|
| create/set/get/destroy round trip, main thread | PASS | PASS |
| Per-thread isolation (spawned worker's binding invisible to main thread's own binding for the same key, and vice versa) | PASS | PASS |
| Exit destructor fires EXACTLY ONCE, with the bound VALUE (not the key) | PASS | PASS |
| Cross-language visibility, Mojo-set value read by real C code via the same key | PASS | PASS |
| Cross-language visibility, C-set value read by Mojo | PASS | PASS |
| Dead key after destroy(): get() reads NULL, set() fails deterministically | PASS (EINVAL, positive-errno convention -- see note) | PASS |
| `pthread_getspecific` allocates NOTHING across 1000 calls (dyld-interposed count, spec SYS-4/§18) | PASS (measured: 0 delta) | SKIP (shim is macOS-only, dyld-interposing; reports SKIP not a false PASS) |

**Positive-errno note**: raw `pthread_setspecific`/`pthread_getspecific`
return the errno DIRECTLY as a positive value (POSIX pthread_* convention),
unlike the `mjs_*` ABI's 0/negative-errno convention this repo's own
`native/posix/mjs_tls.c` wrapper normally translates to -- 22 is EINVAL,
not a sign-convention bug. Also worth recording: darwin's raw
`pthread_setspecific` does NOT validate the key against a per-process
registry the way `mjs_tls.c`'s own registry does after `pthread_key_delete`
-- per POSIX this is genuinely undefined behavior, and `mjs_tls.c`'s header
explains exactly why it keeps its own registry rather than trusting the
raw primitive. This test measured EINVAL on THIS host for THIS key/
generation, which is darwin's libpthread being conservative, not a
portable guarantee -- a production Mojo TLS wrapper still needs its own
registry for the same reason.

## Poller half (issue #126)

Acceptance: "add, modify, remove and wake all work from Mojo against the
kqueue backend, matching the semantics `mjs_poller.c` documents; the same
set works against epoll where a Linux host is available, or the half is
explicitly recorded as CONDITIONAL and epoll is deferred to the poller
implementation in #146; the event buffer crosses the boundary without
copying surprises; a blocked wait returns promptly on an explicit wake
and reports zero events; token values survive verbatim."

| Check | kqueue, macOS arm64 | epoll, Linux AArch64 (docker) |
|---|---|---|
| `struct kevent` / `struct epoll_event` built directly from Mojo (byte pokes at MEASURED/proven offsets, no typed-struct FFI aggregate) | PASS (kevent layout reused from #124's own byte-exact measurement) | PASS (epoll_event offsets measured live by THIS leg's own oracle.c -- see below) |
| wait() with nothing ready: 0 events | PASS | PASS |
| register + write: exactly 1 event, correct fd | PASS | PASS |
| Token survives verbatim (kqueue: full 64-bit `udata`; epoll: `epoll_event.data` used directly for the fd, same design `mjs_epoll.c` uses since the kernel struct has only one 64-bit slot) | PASS | PASS for the fd-as-data convention; a full separate fd->token side-table round trip was not additionally tested -- see "Explicitly unverified" |
| Level-triggered: drained fd reports 0 on next poll | N/A (kqueue tested is edge/`EV_CLEAR`, matching `mjs_poller.c`) | PASS |
| modify/re-register UPSERTS (last interests+token win) | PASS | PASS (re-ADD degrades to MOD on EEXIST, matching `mjs_epoll.c`'s `mjs_epoll_set`) |
| unregister stops delivery even after the fd becomes ready again | PASS | PASS |
| Blocked (infinite-timeout) wait released by wake() from a SEPARATE Mojo-spawned thread | PASS | PASS |
| Woken wait reports ZERO real events (wake source filtered out) | PASS | PASS |

**epoll_event byte layout -- resolves a fact #124's own FINDINGS.md
flagged as unverified anywhere reachable from this repo, on any host**:
measured live on native Linux/AArch64 by this leg's `oracle.c`:
`size=16 events_off=0 data_off=8 packed=0` -- the naturally-aligned
16-byte form (events:4 + pad:4 + data:8), NOT the x86-64-glibc-packed
12-byte form. `poller_epoll_test.mojo` never hardcodes either shape; it
reads these numbers from `oracle_sizeof_epoll_event()` /
`oracle_offset_epoll_event_{events,data}()` at runtime and pokes/reads at
the measured offsets. The x86-64 packed form remains genuinely unverified
(no x86-64 Linux host was exercised -- see "Explicitly unverified" below).

## `entry_pointer` portability (new finding, not in #124's scope)

Every existing S1/S2/S3/S6 test and benchmark in this repo that spawns a
thread uses the SAME `adrp`/`add` + `@PAGE`/`@PAGEOFF` inline-asm idiom to
materialize an `@export`'d function's machine address, and it is Apple
arm64 Mach-O-specific syntax (leading `_` symbol prefix,
`@PAGE`/`@PAGEOFF` relocation modifiers). Confirmed directly: running the
identical idiom on native Linux/AArch64 fails to PARSE
(`error: <inline asm>:1:23: unexpected token in argument list` /
`invalid specifier '@PAGEOFF'`), and the process then segfaults trying to
use whatever garbage address the malformed asm produced. This is real --
every existing test file that uses this idiom (`tests/s2/thread/thread_test.mojo`,
every `tests/s3/sync/*/conformance.mojo`, `tests/s6/io/{poller,epoll}/conformance.mojo`,
and more) has, in practice, never actually run its thread-spawning code on
any Linux host, CI included (the CI wall documented below blocks it
regardless of this asm issue).

The ELF/AArch64 form needs no leading `_` prefix and `:lo12:` instead of
`@PAGEOFF` (plain, unsuffixed `adrp` for the high part) -- verified
working. Every `entry_pointer` in this leg's four test files selects
between the two templates with `comptime if CompilationTarget().is_macos()`,
confirmed correct on BOTH platforms via the docker recipe. This is NOT
filed as a defect (there is no bug -- Mach-O and ELF genuinely use
different relocation syntax for the same ADRP+ADD idiom; a single
hardcoded template was always going to be platform-specific), but it is a
real, useful, NEW finding for #145's audit: any later Phase-2 issue that
spawns Mojo threads on Linux needs this platform branch (or an x86-64
third branch too), and #124's own version of this idiom never actually
ran on Linux either.

## Two comptime-if findings, both load-bearing for cross-platform linking

Confirmed the hard way, both matching and extending mojito-sys#197's own
finding ("no module-level conditional compilation for `@extern`; ...
needs BOTH platforms' externs declared and a `comptime if` at the CALL
site, never a runtime `if`"):

1. **A platform-exclusive extern referenced inside an `@export`'d
   function's body needs a `comptime if` INSIDE that function, not just a
   runtime check in whatever calls it.** `@export`'d functions are real
   ABI-visible symbols the JIT materializes regardless of whether
   anything actually calls them at runtime. `poller_kqueue_test.mojo`'s
   `m13_plr_waker_entry` (which calls `kevent`) needed its OWN internal
   `comptime if not CompilationTarget().is_linux()` guard to link on
   Linux, where `kevent` does not exist -- a runtime early-return in
   `main()` elsewhere in the file did not help.
2. **A platform-exclusive extern referenced anywhere in `main()`'s own
   reachable body -- even after an unconditional runtime `return` on the
   untaken platform -- was ALSO measured to need the real logic moved into
   a separate (non-exported) function, called only from inside a
   `comptime if`.** A plain runtime `if ext.oracle_has_kqueue() == 0: ...
   return` at the top of `main()` was NOT sufficient by itself to keep
   `poller_kqueue_test.mojo` linkable on Linux (finding 1's fix, applied
   alone, still left `main` failing to materialize alongside the exported
   function in the same JIT unit) -- extracting the kqueue-calling logic
   into `_run_kqueue_checks()` and calling it only inside
   `comptime if CompilationTarget().is_linux(): ...print ENVIRONMENT...
   return` fixed it. `tls_test.mojo`'s T6 (macOS-only alloc-probe check)
   hit the same shape: a plain runtime `if CompilationTarget().is_macos():`
   guarding calls to `mjs_alloc_probe_*` (only linked into the macOS-only
   shim dylib) failed to JIT-link on Linux until changed to
   `comptime if`.

`poller_epoll_test.mojo` did NOT need this same extraction (its own
epoll-calling logic stays directly in `main()` after a plain runtime
`if not CompilationTarget().is_linux(): ... return`, and this measured
correctly on BOTH platforms without further changes) -- the working
theory is that a plain (non-`@export`ed) function's code strictly after
an unconditional `return` in the SAME function is reliably eliminated by
ordinary dead-code elimination, while a SEPARATE always-materialized
`@export`ed function's body (or, per finding 2, apparently one specific
measured case of `main()`'s own conditional-block-not-followed-by-return
structure) is not -- but this was not chased down to a first-principles
explanation past the two concrete fixes above. This distinction was
reproduced in isolation during development (throwaway probes, not
committed -- not filed as a docs/defects/ reproducer since there is no
compiler BUG here, only a sharp edge already named in spirit by
mojito-sys#197).

## Compiler defects filed (1, with a minimal reproducer under `docs/defects/`)

| Issue | One-line description |
|---|---|
| mojito-sys#201 | `__moveinit__(out self, owned existing: Self)` parses when imported but fails to parse the identical source run as the main file -- already present, unnoticed, in `mojito_sys/io/poller.mojo`/`io/handle.mojo` |

## Explicitly unverified / deferred

- **x86-64 Linux, for every check above.** Not attempted: would need
  Docker's QEMU-emulated `linux/amd64` on this arm64 host (the repo's own
  `tests/docker/run-linux-lanes.sh` refuses emulated containers for a
  DIFFERENT reason, io_uring_setup returning ENOSYS under emulation --
  that specific trap does not apply to thread/TLS/poller primitives, but
  a third `entry_pointer` asm template for x86-64's different ISA would
  still be needed, and was not written). Per issue #126's own acceptance
  text ("or the half is explicitly recorded as CONDITIONAL and epoll is
  deferred to the poller implementation in #146"), the epoll half's
  x86-64 coverage is exactly that: CONDITIONAL, deferred.
- **CI (`suite-macos`) status at the time this document was written**:
  pushed and pending -- see the PR for the current state. `suite-linux`
  cannot reach this leg regardless of anything in this PR (pre-existing
  condition, see README.md).
- **A full side-table token round trip for epoll** (registering several
  fds with distinct tokens and confirming each one's token survives
  independently through `epoll_wait`) was not additionally exercised
  beyond using `epoll_event.data` directly as the fd, matching
  `mjs_epoll.c`'s own convention. `mjs_epoll.c`'s real token table design
  (a separate fd->token side structure, since the kernel struct has only
  one 64-bit slot) was read and is described in this leg's own test file
  comments, but a from-scratch reimplementation of that table was judged
  out of scope for a feasibility spike (the poller IMPLEMENTATION, not
  just the feasibility question, is M2.5/#146's job).
- **`abi("C") raises` parse-time rejection** was verified on macOS only;
  it is parser behavior with no platform dependency expected, so this was
  not additionally re-run inside the Linux container.
