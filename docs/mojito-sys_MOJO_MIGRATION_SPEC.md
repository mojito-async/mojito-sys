# mojito-sys — Mojo-First Migration Specification

**Status:** Migration specification (supersedes the Rust-substrate plan in
`docs/mojito-sys_IMPLEMENTATION_SPEC.md` for everything below the public
Mojo API)
**Package:** `mojito-sys`
**Program:** Mojito systems libraries
**Target baseline:** Mojo 1.0.0b2 (`mojolang` Homebrew tap), with
compatibility updates for later releases
**Date:** 2026-08-31
**Primary downstream consumer:** `mojito-async`
**Tracking:** epic #121 ("EPIC: M mojo-first migration"), sub-issues
`M<phase>.<n>`

---

## 0. Executive decision

`mojito-sys` moves its production implementation off Clang-compiled C and
into Mojo itself. Mojo calls libc, pthreads and the OS APIs directly
through its own C FFI; a microscopic architecture-specific `.S` layer
keeps the context-switch machine edge; a tiny C shim is allowed only where
Mojo genuinely cannot express a platform ABI construct.

**Rust is not the production substrate and is not a production
dependency.** It may still show up as an optional reference
implementation, a differential oracle, a benchmark comparison, or
throwaway tooling, and nothing more. The earlier plan (still recorded in
`docs/mojito-sys_IMPLEMENTATION_SPEC.md`, referenced below as `spec §N`)
argued for a Rust core hidden behind the same C ABI this repo already
ships; that plan is superseded by this document for everything below the
public Mojo API.

The reason for the turn: buying memory safety by putting a second systems
language underneath the one this project exists to prove out was buying it
at the wrong price. `mojito-async` is meant to be an end-to-end Mojo
stack, and a Rust runtime hiding behind the C ABI would have been a
permanent second toolchain, a second unsafe surface, and a second set of
ownership rules to reconcile with Mojo's own. Writing the mechanism in
Mojo gets the same ownership properties from Mojo's own lifecycle and
origin system, drops a whole toolchain out of the build, and surfaces
missing Mojo compiler/runtime capabilities early instead of routing around
them quietly with someone else's borrow checker.

The C ABI does not go away: it stops being the seam between Mojo and a
native substrate and becomes the seam between Mojo and the operating
system, which is where it was always the most valuable (§1). Mojo's own
binary ABI stays unstable, and that is fine here, because `mojito-sys`
ships primarily as Mojo source compiled by the consuming toolchain (§19).

No flag day. The Clang implementation stays buildable as the behavior and
performance oracle for the whole migration; Mojo lands module by module
behind the same public contract; each C module retires only once its Mojo
replacement passes parity, the relevant MSVS tier, the benchmark envelope,
and an unsafe review (§16, §25).

---

## 0A. Numbering and cross-reference rules

This document has its own section numbers, independent of
`docs/mojito-sys_IMPLEMENTATION_SPEC.md`'s. To keep the two unambiguous
everywhere they are cited, across this whole migration (epic #121 and
every `M<phase>.<n>` sub-issue):

- a bare `§N` (or `§N.M`) resolves **in this document**;
- `spec §N` (or `spec SYS-N`) resolves **in
  `docs/mojito-sys_IMPLEMENTATION_SPEC.md`**, the frozen S0-S6 document
  the shipping C ABI was built against. It is not rewritten by this
  migration except where a specific later phase (`M3.5`, spec §33) says
  so explicitly; until then it stays the authoritative description of the
  Clang implementation that is also this migration's oracle;
- an ADR named `ADR-SYS-NNN` resolves in the old spec's ADR list (§49
  there); an ADR named `ADR-SYS-MNN` is one of this migration's own (§21).

This is the source document every `§N` reference in epic #121's sub-issues
points at, so every section number introduced here is load-bearing: a
later issue that cites `§14` or `§17` is citing the section below with
that number, not a section that issue's author is free to invent
elsewhere.

---

## 1. Layering and architecture

```text
                       mojito-async
                            |
                            v
                      mojito-sys
                         MOJO
                            |
           .----------------+----------------.
           |                |                |
           v                v                v
        libc/POSIX      pthread APIs      OS APIs
        direct C ABI    direct C ABI      direct C ABI
           |                |                |
           +----------------+----------------+
                            |
                     only where required
                            |
                    .-------+-------.
                    |               |
                    v               v
             tiny C shim        tiny .S asm
             ABI adapter        context switch
```

The substrate is Mojo. It calls stable platform C APIs directly. Assembly
exists only for the irreducible context-switch mechanics (§15). A C shim
exists only by documented exception, registered per §14. This sentence,
in these words, is also what lands in `ARCHITECTURE.md` (§24) once M3.2
writes it, so that document and this one never drift from each other.

`mojito-sys` still ships as the same three-layer public shape spec §0
described (public Mojo API, public Mojo C-FFI, native substrate) — what
changes is what sits below the FFI line. Today (pre-migration) that line
is native/*.c calling libc/pthreads/the OS on Mojo's behalf. After the
migration it is Mojo calling libc/pthreads/the OS directly, with the two
exceptions above.

---

## 2. OS, libc and pthread API surface Mojo declares directly

Every OS/libc/pthread entry point `native/` calls today is the surface
Mojo has to be able to call directly, because Phase 2 replaces the C
functions that wrap them, not the underlying calls. `MOJO_MIGRATION_BASELINE.md`
§"OS/libc API surface" carries the full per-file attribution (which file
calls what, and which M1 spike leg proves that call site works from
Mojo); this section is the flattened, deduplicated master list the M1
spike (§6) is sized against, grouped by the leg that has to prove it.

### 2.1 Leg ABI (#124): struct/argument ABI + direct libc/OS calls

- `sysconf(_SC_PAGESIZE)` (page size / allocation granularity);
- `mmap`, `mprotect`, `munmap` (VM reserve/commit/decommit/protect/release,
  non-moving stack allocation);
- `clock_gettime(CLOCK_MONOTONIC)` (Linux) / `mach_absolute_time` +
  `mach_timebase_info` + `pthread_once` (macOS) (monotonic clock);
- `errno` as a thread-local macro-expanding-to-a-function-call on both
  target platforms (the whole ABI contract is 0-or-negative-errno, and it
  collapses if Mojo cannot read it correctly);
- `socket`, `bind`, `listen`, `connect`, `accept`, `recv`, `send`,
  `shutdown`, `close`, `fcntl` (`F_GETFL`/`F_SETFL`/`F_SETFD`,
  `FD_CLOEXEC`, `O_NONBLOCK`), `inet_pton`, `inet_ntop`, `htons`, `ntohs`.

### 2.2 Leg Runtime (#126): thread entry, TLS, poller

- `pthread_create`, `pthread_join`, `pthread_detach`, `pthread_attr_init`,
  `pthread_attr_setstacksize`, `pthread_attr_destroy`, `pthread_self`,
  `pthread_setname_np` (darwin: self-only; Linux: `pthread_t` + name);
- `pthread_key_create`, `pthread_key_delete`, `pthread_getspecific`,
  `pthread_setspecific`;
- `pthread_mutex_init/lock/trylock/unlock/destroy`,
  `pthread_cond_init/wait/timedwait/timedwait_relative_np/signal/
  broadcast/destroy`, `pthread_condattr_init/setclock/destroy`;
- kqueue (macOS/BSD): `kqueue`, `kevent`, `EV_SET`;
- epoll (Linux): `epoll_create1`, `epoll_ctl`, `epoll_wait`, `eventfd`;
- io_uring (Linux, experimental/flagged, spec §28): raw
  `io_uring_setup`/`io_uring_enter` syscalls (no `liburing`), `mmap` of the
  SQ/CQ/SQE rings, `eventfd`;
- futex (Linux): raw `syscall(SYS_futex, ...)` with `FUTEX_WAIT_PRIVATE` /
  `FUTEX_WAKE_PRIVATE`; the macOS fallback composes the mutex/condvar
  surface above instead of a private kernel interface (spec §18 forbids
  one) — Mojo needs no new OS call for that path, only the mutex/condvar
  ones already listed.
- CPU topology/affinity: `sysconf(_SC_NPROCESSORS_ONLN)`,
  `sysctlbyname("hw.physicalcpu")` (macOS), `/sys/devices/system/cpu/.../
  topology/{physical_package_id,core_id}` (Linux, best-effort),
  `sched_setaffinity` (Linux), `thread_policy_set` + `mach_thread_self` +
  `mach_task_self` (macOS).

### 2.3 Leg Stack/Switch (#128): the assembly edge

No additional OS/libc calls beyond Leg ABI's `mmap`/`mprotect`/`munmap`:
this leg is about whether ordinary Mojo frames survive a register-level
context switch, not about a new syscall surface. The callee-saved
register set each backend must preserve (AArch64: `x19`-`x28`, `fp`,
`lr`, `d8`-`d15`, `sp`; x86-64 SysV: `rbx`, `rbp`, `r12`-`r15`, low 64
bits of `xmm6`-`xmm13`, `rsp`) is an ABI fact, not an OS call, and is
recorded in the ABI-layout half of the baseline instead.

### 2.4 Rule

No conversion issue (`M2.1`-`M2.5`) may add a native OS/libc call to its
Mojo declarations that is not already in this list or explicitly
justified as new surface in that issue's own body. A call that shows up
in the built dylib's actual behavior but is missing here is a baseline
gap, not license to skip declaring it — file it against #122's inventory
and extend this section in the same change.

---

## 3. Design principles carried forward

The seven principles in `spec §3` (`SYS-1` mechanism-not-policy through
`SYS-7` platform differences stay visible) are reaffirmed unchanged for
Mojo-first; this migration does not relitigate them, only their
implementation language. Two read differently once the substrate is Mojo
rather than a C wrapper around Mojo:

- **spec SYS-2 (C ABI firewall).** The firewall used to sit between Mojo
  and this repo's own C. It now sits between Mojo and the operating
  system (§1) — the same principle, one layer down.
- **spec SYS-4 (no hidden allocation on primitive fast paths).** This was
  a claim about the C implementation; it becomes a claim about the Mojo
  implementation, and "no hidden allocation" only stays true if it is
  measured, not assumed. §18 makes measurement mandatory.

---

## 4. Scope and non-goals

Unchanged from spec §5 and the epic's own "Preserved constraints" (§22):
no scheduler, no `Future`/executor model, no `Scope`/`Task`/`JoinHandle`,
no channels, no work stealing, no cancellation, no Tokio, no Rust async
anywhere, no dependency on Mojo's current `AsyncRT`, no `Task.wait()`
standing in for fiber parking. `mojito-sys` is mechanism; policy belongs
to `mojito-async`.

What is newly in scope relative to the plan spec §0 described: Mojo
calling libc/pthreads/OS APIs directly is no longer aspirational, it is
the deliverable, and "port `native/*.c` to Rust instead" is explicitly
out of scope — §8's NO-GO path reopens the substrate-language question,
it does not fall back to Rust by default.

---

## 5. Phase sequence and gates

```text
PHASE 1  baseline and the Mojo-native feasibility gate
   M1.1 baseline, inventory, pre-migration numbers      <-- this document
      |
      v
   M1.2 / M1.3 / M1.4   spike legs, run in parallel (§6)
      |  ABI+libc         thread/TLS/poller      stack + .S switch
      v
   M1.5 audit and spike verdict   <-- HARD GATE (§8: GO / CONDITIONAL GO / NO-GO)
      |
======|===========================================================
      v
PHASE 2  Mojo substrate implementation
   M2.1 ABI and platform declarations in Mojo
      |          .---------------+---------------.
      |          v                               v
      |     M2.2 memory/stack            M2.3 thread/TLS/sync/time
      |          '---------------+---------------'
      |                          v
      |                 M2.4 context + .S seam
      |                          v
      |                 M2.5 sockets/pollers
======|===========================================================
      v
PHASE 3  verification, packaging, retirement and closure
   M3.1 / M3.2 test and safety expansion (start during M2.1, finish last)
   M3.3 MSVS CI tiers, Mojo-source packaging, contributor docs
   M3.4 Clang retirement, release MSVS run, completion report
   M3.5 spec rewritten as Mojo-normative, ADRs landed
======|===========================================================
      v
PHASE 4  cut the mojito-async consumer over
   M4.1 inventory the consumer's call sites, settle the ABI gap
   M4.2 close the substrate drift the vendored fork hides
   M4.3 / M4.4  repoint context, then io/thread/pool; delete the vendored tree
   M4.5 handoff gate at spec §46, against the real substrate
```

No conversion work of any kind (Phase 2 onward) starts before the M1.1
baseline (this document plus `MOJO_MIGRATION_BASELINE.md`) is complete,
and none starts before M1.5 records a GO or accepted CONDITIONAL GO (§8).
This is a hard ordering rule, not a scheduling preference: without a
complete baseline there is nothing to hold a Mojo replacement's parity,
performance, or size claim to, and without a spike verdict there is no
evidence Mojo can do the hardest 20% of this job at all.

---

## 6. The M1 spike: legs

The M1 spike (Phase 1, `M1.2`-`M1.5`) is one hard go/no-go gate split into
three legs that run in parallel, because a failure in the hardest cases is
cheaper to find in a four-week spike than three months into Phase 2.

| Leg | Issue | Proves | OS surface |
|---|---|---|---|
| **ABI** | #124 | Mojo can describe the OS's C structs byte-exactly and call libc/the OS directly, including reading `errno`, from ordinary (non-leaf) Mojo frames | §2.1 |
| **Runtime** | #126 | A Mojo `abi("C")` function can run as a real `pthread_create` entry point, own TLS, and drive a native kqueue/epoll poller end to end | §2.2 |
| **Stack/Switch** | #128 | A Mojo-owned non-moving stack holds up under allocation storms, and ordinary Mojo frames survive an external `.S` register-level switch onto and off of it | §2.3 |

`M1.5` (#145) audits all three legs against §8's criteria and writes
`MOJO_NATIVE_SPIKE_REPORT.md`. Every inventory row in
`MOJO_MIGRATION_BASELINE.md` that says "which spike leg covers it" points
at one of these three rows.

---

## 7. M1 spike hypothesis

Spec §6.1 asked whether an ordinary Mojo call chain survives an external
stack switch through a C-ABI seam — S0 (`spike/context_switch/`) answered
that question and it is closed, GO, per
`spike/context_switch/SPIKE_REPORT.md`.

The Mojo-first question is harder: whether the same ordinary Mojo call
chain survives that switch **with the C substrate gone**, i.e. with Mojo
calling a bare `.S` symbol directly (or through the thinnest possible
adapter, §15) rather than through `native/posix/ms_context.c`'s C
dispatch layer. S0 proved the frames survive when C sits in the loop; M1
(specifically leg Stack/Switch, #128) has to prove they still survive
once C is no longer the thing doing the calling.

Hypothesis: an ordinary Mojo function chain (`A() -> B() -> C() ->` a
directly-called `.S` switch symbol `-> ` an alternate context `->` switch
back `->` `C()` returns `->` `B()` returns `->` `A()` returns) preserves
every property S0-T1 through S0-T14 already established — stack-local
address stability, borrow validity, exactly-once destructors, `raises`
propagation, register preservation, alignment, and freedom from private
Modular runtime symbols — with no C function anywhere in that call chain
except the switch's own machine-level entry.

---

## 8. M1 spike verdict: GO / CONDITIONAL GO / NO-GO

`M1.5` (#145) records one verdict, following this section rather than
taste:

**GO** when direct C FFI works for every OS primitive §2 lists, native
thread callbacks work, TLS works, the representative ABI structs pass the
oracle checks (byte-exact size/alignment/offsets against a C oracle, not
against a checked-in copy of one), the native poller works end to end,
`NativeStack` ownership is sound (non-moving, exactly-once release,
guard-page fault behavior matching `native/posix/mjs_stack.c`), ordinary
Mojo frames survive the `.S` stack switch, and no broad native
implementation layer turned out to be structurally necessary.

**CONDITIONAL GO** for bounded gaps, each named with its condition and an
owner: one platform API needing a tiny shim (§14 prices it), one struct
layout needing generated constants instead of a hand-written Mojo
declaration, incomplete debugger/unwinder support for the synthetic
stack, a deferred non-critical platform (Windows is already deferred by
policy, §20, so it does not itself trigger a CONDITIONAL GO), or one
contained compiler-bug workaround with a documented reproducer. A
CONDITIONAL GO is not a soft NO-GO: Phase 2 proceeds, and the named
conditions become tracked issues under their owning Phase-2 milestone.

**NO-GO** only for structural failures: Mojo cannot make the required OS
calls from ordinary (non-leaf-module) frames at all; Mojo cannot own TLS
correctly; the representative structs cannot be laid out byte-exact by
any available Mojo declaration form; or ordinary Mojo frames do not
survive the direct `.S` switch (corrupted locals, dangling borrows,
skipped or doubled destructors, broken `raises` propagation, or
register/alignment corruption that repeats under load).

A NO-GO **stops the conversion** and reopens the substrate-language
question explicitly — including reconsidering Rust as a fallback — rather
than defaulting back to it. Nothing in this document authorizes treating
a NO-GO as "revert quietly to the Rust plan"; that is a decision this
document's authors make again, in the open, against whatever the NO-GO's
evidence actually shows.

---

## 9. Repository and package layout

The repository already has the `mojito_sys/` tree at the root with the
subpackage split a from-scratch layout would ask for (`abi/`, `memory/`,
`io/`, `thread/`, `sync/`, `time/`, and `ctx/` once M2.4 lands it), so this
migration does **not** reorganize it for aesthetics. Specifically:

- `mojito_sys/` stays at the repository root, not nested under a `mojo/`
  directory;
- `native/posix/*.S` (`ms_context_aarch64.S`, `ms_context_x86_64.S`) keeps
  its home under `native/posix/` rather than moving to a hypothetical
  `native/asm/`;
- `native/shim/` is created only once a C shim is actually approved under
  §14 — it does not exist speculatively;
- `spike/context_switch/` stays exactly where it is: it is oracle/history,
  not something the migration reorganizes or deletes (§10, §16).

A file mover with no behavior change is not a migration deliverable in
this repository; every PR in this epic changes what a file *is*
(C to Mojo, or spec-to-spec), not merely where it lives.

---

## 10. M0 — pre-migration native inventory and baseline

M0 is this issue (#122): the pre-migration snapshot every later phase is
held to. It has two halves, and their order is not incidental — the
inventory has to exist before a measurement can be said to cover it.

**10.1 Inventory (first half).** Every native source under `native/` and
`spike/context_switch/` gets a role, a platform-reach note, and a
Mojo-fate classification (replace / wrap / keep-as-oracle); the exported
symbol set (`mjs_*` + `ms_context_*`) is captured from the built
`libmojito_sys.dylib` with `nm`, via a committed, rerunnable script
(`tools/migration_baseline/gen_symbol_inventory.sh`), never transcribed
from the header by hand; the ABI structs/typedefs/function-pointer
types/constants from `native/include/mojito_sys.h`, plus the OS structs
the implementation consumes but never exports, get size/alignment/field
offsets from an actual C oracle program on the reference host
(`tools/migration_baseline/abi_oracle.c`), never copied from a comment;
platform divergence (macOS vs. Linux, and which "POSIX" paths are really
macOS-only) is recorded per file; current Clang flags, Makefile lanes,
and sanitizer jobs are recorded as they exist today; every file gets a
conversion-difficulty class. All of this lives in
`MOJO_MIGRATION_BASELINE.md`'s first half, not duplicated here.

**10.2 Baseline (second half).** Once the inventory exists, MSVS is run
and recorded in the machine-readable form spec §38.16 defines; every §17
primitive is benchmarked against its current Clang implementation (or
explicitly marked "no baseline, Mojo is the first implementation" when
there genuinely is no Clang counterpart — there is no such row left as of
this migration, since sockets, both pollers, the semaphore, and the
x86-64 switch have all landed in C since the earlier plan was written);
`libmojito_sys.dylib` size, a linked minimal Mojo executable's size, and
the exported symbol count are recorded; allocation counts are measured
(not asserted) on the fast paths spec SYS-4 promises are allocation-free.
This also lives in `MOJO_MIGRATION_BASELINE.md`, in its second half.

**10.3 The rule.** No conversion work (Phase 2 onward, and no spike leg
work either — Phase 1's own §6 legs still need this inventory to know
what they are proving) starts before both halves are committed with no
placeholder rows. A later ABI diff, benchmark comparison, or size claim
is only as honest as this baseline; treat a gap found here as a blocking
defect in the baseline, not as something a later phase can quietly work
around.

---

## 11. MSVS under Mojo-first

Spec §38 defined the Mojito Systems Validation Suite as one integrated
battery. Under Mojo-first it is four layers instead of one:

1. the C ABI oracle layer (does the built artifact — Clang today, Mojo's
   linked output later — actually match the byte-exact contract?);
2. Mojo safety and ownership (does the Mojo implementation itself hold
   its invariants — no double-free, no aliased mutable, no leaked
   handle?);
3. OS behavior (does the observable behavior match the OS's actual
   contract, independent of which language issued the call?);
4. performance (§17).

The C oracle/reference code is **retained permanently** — through Clang
retirement (`M3.4`) and past it — as the layer-1 comparison target for as
long as `mjs_abi_version` and the dynload contract stay meaningful, which
per the epic's own scope note is through `M3.4` at least. "Permanent
oracle, not scaffolding" is the ADR `M3.5` files (ADR-SYS-M4, §21); this
section is where that decision is first written down.

Mojo results land in the same spec §38.16 machine-readable report
everything else already feeds, tagged so a dashboard can tell a Mojo
result from a Clang one for the same test name.

---

## 12. No Miri: what replaces it

Mojo has no Miri equivalent, and pretending otherwise would be the
quietest way to lose the safety argument this migration is built on
(spec §35's sanitizer/tooling section already notes Mojo's sanitizer
story is thinner than Clang's; this is the sharper version of that gap).
The compensation, standing in wherever this document or a later issue
cites "§12", is five things together, never any one alone:

1. **Explicit unsafe review** — every unsafe operation in the Mojo
   substrate gets a `SAFETY.md` entry in the §13 shape;
2. **Generated-input tests** over conversion/decode paths, where boundary
   bugs actually hide;
3. **The C ABI oracle** (§11 layer 1) as a permanent differential check;
4. **Fault injection** — deliberately failing the Nth allocation/syscall
   and checking recovery, mirroring spec §38.11;
5. **High-iteration stress and deterministic resource-lifecycle tests** —
   every owning type constructed and destroyed across normal, error, and
   early-return paths with the release actually counted, not assumed
   (the same discipline §18 asks of allocation counts).

`M3.1`/`M3.2` own the test-authoring half of this (items 2 and 5); the
standing-gate half (items 1, 3, 4 — what the code is allowed to contain,
enforced continuously) is a separate, later concern this document does
not resolve on their behalf, only names.

---

## 13. `SAFETY.md` entry shape

Every unsafe operation the Mojo substrate contains gets one entry:

```text
operation:            <what unsafe thing this is>
why unsafe required:  <what Mojo's type system cannot prove here>
pointer validity:     <how it is established>
lifetime:             <who owns it, how long it is valid>
ownership:            <transferred / borrowed / shared, and to whom>
thread requirement:   <single-thread-only / caller-serialized / lock-free>
alignment:            <required alignment and how it is guaranteed>
OS guarantee relied on:<the kernel/libc contract this leans on>
tests covering it:     <which test(s) exercise the invariant>
```

This is the format `M3.2` (#151) fills in per module and `M2.4` (#142)
seeds first for the context/switch entry, since that module carries the
highest unsafe-review weight in the package (§15).

---

## 14. C shim policy

A tiny C shim is permitted **only** where Mojo genuinely cannot express a
platform ABI construct, and every one that exists must be:

1. **registered** — named, with the file it lives in (`native/shim/...`,
   created only once the first one is approved, §9) and the issue that
   approved it;
2. **justified by an ADR** — a short ADR-SYS-MNN (§21) stating what Mojo
   construct is missing and why the shim is the smallest correct
   response;
3. **priced in lines of C** — the shim's line count is the number that
   gets weighed against "how much C survives the migration," so it is
   reported, not hidden inside a bigger file.

`mjs_ctx_call.c` (`native/posix/mjs_ctx_call.c`, 31 lines) is the existing
precedent and the shape every future shim should match: a single-purpose
dispatch function moving one indirect branch out of Mojo-generated code
because that construct crashes the pinned 1.0.0b2 JIT (documented in the
file itself and in `spike/context_switch/SPIKE_REPORT.md` item 5), doing
nothing else. A shim that grows past a single narrow purpose is a sign
the exception is being used as a rug for a bigger unsolved problem, not a
documented, bounded workaround.

---

## 15. Assembly (`.S`) seam policy

Architecture-specific assembly is retained **only** for the irreducible
context-switch mechanics: the register-level save/restore/resume that no
higher-level language construct (Mojo included) can express without
either losing control over exactly which registers move or accepting a
call-stack round trip the switch cannot afford. Today that is
`native/posix/ms_context_aarch64.S` and `native/posix/ms_context_x86_64.S`
(and, pre-migration, `spike/context_switch/aarch64_switch.S` as their
oracle predecessor, §16).

The open question this section exists to eventually close, and which
`M1.4` (#128) is sized to answer: **how thin can the seam get?** Two
shapes are possible —

- Mojo calls the existing `.S` symbol (`_ms_context_switch` /
  equivalent) through a plain `abi("C")` declaration with no C in
  between, or
- an irreducible C or Mojo adapter has to sit between Mojo and the raw
  `.S` symbol (for example, if Mojo cannot materialize the function
  pointer the trampoline resumes into without going through
  `mjs_ctx_call`'s dispatch pattern, §14).

If the second shape is what `M1.4` finds, the adapter's exact line count
is the deliverable, because §14 makes that number the price of the
exception — this section does not get to wave that cost away just
because the seam is "supposed to be assembly."

---

## 16. Differential testing rule

Every file that is a genuine **port** — meaning a real C implementation
with observable behavior already exists and Mojo is replacing it, not
implementing something for the first time — gets compared against its C
oracle on every deterministic code path, for the life of that C
implementation (through `M3.4` at minimum, and the oracle itself survives
past that per §11).

This applies in full to `native/posix/mjs_socket.c`, `mjs_poller.c`
(kqueue), `mjs_iouring.c`, `mjs_epoll.c`, `mjs_sem.c`, and
`ms_context_x86_64.S` — all landed since the earlier (Rust-substrate)
version of this plan was written, closing #72, #74, #75, #76 and #78, and
all now genuine ports with a real C oracle behind them rather than the
"nothing to port" the old plan recorded for I/O. It does not apply to
Windows/IOCP (§20), which has no Clang implementation to differ against
in this repository and stays deferred until Mojo has a usable Windows
target.

A file with no Clang counterpart at all is recorded in
`MOJO_MIGRATION_BASELINE.md` as "no baseline, Mojo is the first
implementation" rather than left as a blank row (§10.2) — as of this
migration, every §17 primitive clears that bar; there is no such row.

---

## 17. Performance-critical primitives

Every primitive below has a Clang implementation to measure against
today (§10.2), and the Mojo replacement for each one is held to "no
material hot-path regression without written justification" once it
lands (`M2.1`'s bench harness, #129, encodes the acceptance rule; this
section names the rows):

1. FFI no-op crossing
2. page-size query
3. VM reserve/release
4. VM commit/decommit
5. thread create/join
6. TLS get/set
7. monotonic clock read
8. native event wait/wake
9. context switch
10. poller add/remove
11. poller wake
12. socket loopback round trip

**What "FFI no-op crossing" measures changes shape across the migration.**
Under Clang it measures Mojo calling this repository's own C function
(today: `mjs_abi_version()`, chosen for having essentially no C-side
work). Under Mojo-first the equivalent hot path is Mojo calling libc
directly, and for a lot of rows there is no crossing left to measure at
all, because the wrapper function disappeared along with `native/*.c`.
Whatever harness reports these numbers states, per row, which two things
it is actually comparing — never pretends a "Mojo calling our C" number
and a "Mojo calling libc directly" number are the same measurement with
different labels.

**Acceptance rule** (`M2.1`'s bench harness enforces this numerically):
FFI crossing overhead stays effectively equivalent to the pre-migration
baseline; context-switch cost stays inside the envelope issue #69
established; any statistically reliable regression over 5% on a
designated hot-path primitive blocks merge until reviewed and either
fixed or explicitly accepted with a written reason.

---

## 18. Allocation-counting methodology

"No hidden allocation" (spec SYS-4) is a claim, and a claim about the
Mojo replacements can only be checked against something if the C
baseline was actually counted rather than assumed from the header
comment that says "allocation-free." §10.2's allocation-count rows are
produced by actually intercepting the allocator (a dyld-interposing
`malloc`/`calloc`/`realloc`/`free` counter on the macOS reference host,
`tools/migration_baseline/alloc_probe_shim.c`) across a warmed-up,
steady-state loop of each fast path, not by reading the source and
trusting its own comment.

Two things this methodology is careful to separate, because folding them
together would misreport a real primitive as allocating on its hot path
when it does not:

- **One-time lazy initialization** (for example, the macOS
  atomic-wait/wake fallback's 256-slot waiter table, built once behind
  `pthread_once` on the first call anywhere in the process) is measured
  and reported **separately** from steady-state per-call cost. A
  primitive that allocates once, ever, per process, and never again is
  not the same claim as one that allocates every call.
- **Primitives the header does not claim are allocation-free** (thread
  spawn is the example: it `calloc`s one handle per spawned thread by
  design) are measured too, but their nonzero count is not a defect —
  it is the row confirming the claim the header actually makes, which is
  narrower than "nothing here ever allocates."

The same separation applies when Mojo replacements are measured later:
report steady-state and one-time-init costs as different numbers, and
report a primitive's actual documented allocation contract rather than a
blanket "should be zero" for everything.

---

## 19. Packaging

`libmojito_sys.dylib` versus `libmojito_sys.a` was the earlier plan's
argument to have; Mojo-first mostly dissolves it. The released package
under this migration is **Mojo source**, plus whatever tiny per-target
`.S` files (§15) and approved shim objects (§14) survive, distributed
without depending on a stable Mojo binary ABI — Mojo's own binary ABI is
unstable, and `mojito-sys` does not need it to be stable, because it
ships as source the consumer's own toolchain compiles.

`libmojito_sys.dylib` survives the migration as the **C oracle and
reference build** (§11, §16), not as the shipped product. Neither the
dylib nor a hypothetical static archive is "the artifact" any more;
`mjs_abi_version()` and the dynload contract stay meaningful for exactly
as long as the Clang reference stays buildable, which is through `M3.4`
at minimum.

---

## 20. Windows and IOCP: deferral policy

Windows, IOCP included, is **deferred entirely** until Mojo has a usable
Windows target. This is not a gap this migration is expected to close: no
Clang implementation of the Windows backends exists in this repository
today (the header's own POSIX-only implementation notes make this
explicit throughout `native/include/mojito_sys.h`), so there is nothing
to port and nothing to differentially test against (§16). Every table in
`MOJO_MIGRATION_BASELINE.md` that would otherwise have a Windows row
records its absence explicitly rather than leaving a blank cell — an
honest missing row, not a silent one.

---

## 21. Migration-specific ADRs

The old spec's ADR list (spec §49) stops at `ADR-SYS-008`. The decisions
this migration makes get recorded after it, under an `M`-prefixed
numbering that keeps them visibly the Mojo-first set without renumbering
anything upstream:

| ADR | Decision | Landed by |
|---|---|---|
| `ADR-SYS-M1` | Mojo is normative for production mechanism; Rust is never a production dependency | this document, §0 |
| `ADR-SYS-M2` | Status-code convention: the shipping `int`/0-or-negative-errno contract under `mjs_*`/`ms_context_*` wins over both the `ms_status` and `McStatus` sketches the earlier plan left inconsistent | `M2.1` (#129) |
| `ADR-SYS-M3` | Packaging: Mojo source + tiny per-target `.S`/shim artifacts is the shipped product; the dylib is the retained oracle, never the product (§19) | this document, §19 |
| `ADR-SYS-M4` | The C oracle/reference build is permanent infrastructure through Clang retirement, not scaffolding to delete once Mojo lands (§11) | `M3.5` (#159) |
| `ADR-SYS-M5` | Windows/IOCP stays deferred until a usable Mojo Windows target exists (§20) | this document, §20 |
| `ADR-SYS-M6` | A NO-GO at the M1 gate reopens the substrate-language question explicitly; it does not default back to Rust (§8) | this document, §8 |

`M3.5` is the issue that writes the full ADR text for each of these
(matching the old spec's ADR format, spec §49) and reconciles this table
against what actually landed.

---

## 22. Preserved constraints

Unchanged from the epic's own list, restated here since this is the
document every `§22` cross-reference resolves against: no scheduler and
no `Future`/executor model in `mojito-sys`; no Tokio and no Rust async
anywhere; no dependency on Mojo's current `AsyncRT` and no `Task.wait()`
standing in for fiber parking; non-moving native stacks; the strict S0
context-switch gate (§7, §8); the direct-style `mojito-async` design; C
ABI and platform contract validation; MSVS (§11); performance regression
testing (§17); a tiny native machine edge (§14, §15).

A native poller wait, mutex lock, or condvar wait blocking its OS thread
under §2's direct calls is expected and correct; what §22 forbids is
any of that blocking being routed through, or made to cooperate with,
Mojo's `AsyncRT` or a task/scheduler abstraction. "Genuinely blocking,
not something the runtime tries to be clever about" (per #126's own
framing of the poller leg) is the test.

---

## 23. Open questions

- **PAC/`arm64e` enforcement.** `native/posix/ms_context_aarch64.S`
  inherits the S0 spike's limitation: built with default `arm64` codegen,
  return addresses are unsigned and `pacibsp`/`autiasp` pairing is
  absent. Under `arm64e`/PAC enforcement the saved `lr` would need
  signing per frame, and every downstream Mojo frame would need matching
  PAC support. Recorded as an explicit limitation, not fixed by this
  migration.
- **x86-64 SysV context support.** `ms_context_x86_64.S` is a
  cross-assembled structural mirror only (built on the Darwin/arm64
  reference host, cannot execute there); it is not
  `NativeContext`-supported until the frozen `fps` bank grows to hold
  the full 128-bit SysV callee-saved SIMD set (`xmm14`/`xmm15` currently
  omitted) and a Linux/x86-64 runner exists to prove it (spec §38.6).
  Whether that upgrade happens inside this migration or after it is not
  settled by this document.
- **Generated vs. hand-written platform constants.** `M2.1` (#129) has to
  decide whether numerically divergent constants (`AF_INET6`, `O_NONBLOCK`,
  `EV_*`, `EPOLL*`) are generated from host headers at build time or
  hand-verified per platform; this document does not pre-decide it,
  only requires that whichever way it goes, a deliberately wrong value
  fails the build.

---

## 24. Deliverables

`MOJO_MIGRATION_BASELINE.md` (this issue); `MOJO_NATIVE_SPIKE_REPORT.md`
(`M1.5`); updated `docs/mojito-sys_IMPLEMENTATION_SPEC.md` (`M3.5`, spec
§33 and related sections); `SAFETY.md` (`M2.4` seeds it, `M3.2`
completes it, §13); `ARCHITECTURE.md` (`M3.2`, §1); MSVS results in the
spec §38.16 machine-readable format (§11); the Clang-vs-Mojo benchmark
report (§17, `M2.1`'s harness plus every later conversion issue's added
rows); the Clang-vs-Mojo parity report (§16); `MOJO_MIGRATION_COMPLETION_
REPORT.md` (`M3.4`).

---

## 25. Definition of done

- [ ] Mojo is the normative implementation language for production
      `mojito-sys`, and this spec says so (§0).
- [ ] Rust is not required by any production build.
- [ ] Platform C APIs are called from Mojo directly wherever practical
      (§2).
- [ ] Tiny C shims exist only where an ADR justifies them, and each one
      is registered (§14).
- [ ] Context switching is isolated to minimal audited `.S` (§15).
- [ ] The M1 Mojo-native spike is GO, or a CONDITIONAL GO whose
      conditions are recorded and accepted (§8).
- [ ] `NativeStack` ownership is implemented in Mojo.
- [ ] VM management is implemented in Mojo.
- [ ] Threads, TLS, time and synchronization are implemented in Mojo.
- [ ] Sockets and pollers are implemented in Mojo for supported
      platforms.
- [ ] All C ABI oracle tests pass (§11, §16).
- [ ] All relevant MSVS tests pass (§11).
- [ ] Context register, alignment, destructor and `raises` tests pass.
- [ ] Performance sits inside the approved regression thresholds (§17).
- [ ] No large C or Rust implementation layer hides under the Mojo
      facade.
- [ ] Clang production modules are retired, or retained only as
      documented fallback and reference code (§11, §19).
- [ ] The `mojito-async` handoff gate (spec §46) passes against the
      Mojo-first substrate.
- [ ] The main spec carries no stale Rust-as-production and no stale
      prefer-C language (`M3.5`, spec §33).

None of these boxes are checked by this document. Landing this document
and `MOJO_MIGRATION_BASELINE.md` closes exactly one thing: `M1.1`, the
baseline every later box above is measured against.
