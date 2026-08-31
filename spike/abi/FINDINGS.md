# M1.2 abi spike — findings

Measured results against issue #124's acceptance criteria. Everything
below is a real, dynamically-verified result on macOS arm64 (Darwin
25.6.0, Mojo 1.0.0b2 2cf4d08a, homebrew mojolang tap) unless marked
CI-pending or explicitly unverified. Re-run: `cd spike/abi && ./run.sh`.

## Half 1 — struct layout

Acceptance: "every struct above has a Mojo declaration whose size,
alignment and field offsets match the C oracle exactly on macOS AArch64
and on Linux x86-64 and AArch64; the round-trip pattern tests pass in
both directions; by-value and by-pointer argument passing both verified;
any struct Mojo cannot express is written up with what it would need
rather than skipped."

| Struct | macOS arm64 | Linux x86-64 (CI) | Linux AArch64 |
|---|---|---|---|
| `timespec` | size+offsets+round-trip: PASS | CI-pending | no CI lane, unverified |
| `timeval` | size+offsets+round-trip: PASS (tv_usec width measured: 4 bytes darwin) | CI-pending (Linux branch coded, tv_usec: 8 bytes, unverified locally) | no CI lane, unverified |
| `sockaddr_in` | size+offsets+round-trip: PASS | CI-pending | no CI lane, unverified |
| `sockaddr_in6` | size+offsets+round-trip: PASS | CI-pending | no CI lane, unverified |
| `sockaddr_un` | size+offsets+round-trip: PASS (sun_path cap 104 measured) | CI-pending (Linux branch coded, cap 108 per baseline, unverified locally) | no CI lane, unverified |
| `sa_family_t`/`socklen_t` | sizes reported (1/4 bytes darwin) | CI-pending | no CI lane, unverified |
| `iovec` | size+offsets+round-trip: PASS | CI-pending | no CI lane, unverified |
| `kevent` | size+offsets+round-trip: PASS; **alignment mismatch documented** (see below) | N/A (BSD/macOS only) | N/A |
| `epoll_event` | N/A (Linux only) — reports ENVIRONMENT/SKIP | CI-pending, x86-64 packed-vs-unpacked untested here | **no CI lane exists in this repo; AArch64 packing fact is unverified anywhere reachable from this repo** |
| `pthread_attr_t` | opaque size/align (64/8) + REAL `pthread_attr_init`/`getstacksize`/`destroy` round trip: PASS | CI-pending | no CI lane, unverified |
| `pthread_mutex_t` | opaque size/align (64/8) + REAL `pthread_mutex_init`/`lock`/`unlock`/`destroy` round trip: PASS | CI-pending | no CI lane, unverified |

By-value / by-pointer argument passing:
- `timespec` (16 bytes, register-pair sized): passed BY VALUE into C and
  returned BY VALUE from C, both directions verified PASS. This works
  from an ordinary (non-leaf) Mojo frame; the existing repo convention
  had never tried by-value struct FFI at all before this spike.
- Bigger structs (`sockaddr_un`, `kevent`, etc.): by-pointer both
  directions, verified PASS via the round-trip tests above.

Struct Mojo cannot express exactly: **`kevent`**. Apple's `<sys/event.h>`
wraps it in `#pragma pack(4)`, forcing real ABI alignment to 4 despite
every member being naturally 8-byte aligned. Mojo's natural struct
layout computes alignment 8 (no packing/alignment-override attribute
exists — probed directly, `@packed` is "unknown declaration"). Size and
every field offset still match exactly (verified) because the struct's
tail field lands on a 32-byte boundary already, so this is harmless for
THIS struct specifically but is a real declaration gap for any future
struct whose tail doesn't land on an 8-byte boundary. Filed as
mojito-sys#198 (feature gap, not a crash) with what full fidelity would
need: a struct-level packing attribute, or a documented policy of
falling back to a byte-blob-with-manual-offsets for structs that need
sub-natural alignment.

**Genuine defect found via the round-trip methodology, not theorized**:
an earlier draft declared `sockaddr_in6.sin6_addr` and `sockaddr_in.
sin_zero` as `SIMD[DType.uint8, N]`. `SIMD[DType.uint8, 16]` carries
16-byte VECTOR alignment when embedded as a struct field — incompatible
with C's 1-byte-aligned byte array — and this was caught ONLY because
the byte-pattern round trip against the live C oracle failed (size 48 vs
C's 28, offset 16 vs C's 8). Fixed by switching to `InlineArray[UInt8,
N]`, which lays out C-compatibly (verified). Filed as mojito-sys#194.
This is exactly the class of bug issue #124 warns about ("a silent
one-byte padding difference... shows up as a mysterious EINVAL six
workstreams later") and is the strongest argument in this leg for why
the dynamic-oracle methodology is load-bearing, not optional.

## Half 2 — direct libc/OS calls

Acceptance: "each call above is made directly from Mojo and produces the
same result as the equivalent C oracle call for the same inputs, error
paths included; errno is read correctly from Mojo on macOS and Linux and
matches the oracle for at least three distinct failure modes; the
variadic and macro-shaped calls are either working or listed as shim
candidates with a line count; the leaf-module constraint is either shown
to be unnecessary here or documented as a structural constraint."

| Call | macOS arm64 | Linux (CI) |
|---|---|---|
| `sysconf(_SC_PAGESIZE)` | PASS, matches oracle | CI-pending |
| `mmap`/`munmap`/`mprotect` | PASS (reserve, write/read through it, reprotect, release) | CI-pending |
| `clock_gettime(CLOCK_MONOTONIC)` | PASS, matches oracle within 1s, monotonic across two reads | CI-pending |
| `mach_absolute_time`+`mach_timebase_info` | PASS (macOS-only "honest path"), matches oracle within 1s | N/A |
| `socket`/`close` | PASS | CI-pending |
| `read` | PASS (direct `@extern`) | CI-pending |
| `write` | PASS, but via `std.io.FileDescriptor.write()` — see mojito-sys#195, a custom `@extern("write")` conflicts with the stdlib's own internal binding | CI-pending |
| `recv`/`send` | PASS, byte-exact payloads both directions | CI-pending |
| `fcntl` (2-arg and 3-arg) | PASS — `F_GETFL` reads the real flags, `F_SETFL` demonstrably changes them | CI-pending |
| `open` (2-arg and 3-arg) | PASS on `/dev/null` | CI-pending |
| `ioctl` (`FIONREAD`, 3-arg) | call itself succeeds/reachable; **pointer write-through NOT observed — mojito-sys#196** | CI-pending |

errno: read directly via the platform's real accessor (`__error()` on
macOS; `__errno_location()` declared and selected via `comptime if` for
Linux, CI-pending) across three distinct, deliberately-triggered failure
modes, each diffed against the oracle forcing the identical failure:

- **EBADF** — `close(-1)`: PASS.
- **EINVAL** — `mprotect()` on a misaligned address: PASS.
- **EAGAIN** — `recv()` on an empty non-blocking socket: PASS.

Variadic/macro-shaped entry points:
- `fcntl`, `open`: WORKING, fixed-arity declarations, values verified to
  actually reach the real syscall.
- `ioctl`: the pointer-out-parameter form (`FIONREAD` and anything
  similarly shaped) is a **shim candidate**, not working directly.
  Suspected cause: Apple's arm64 ABI passes true variadic arguments on
  the stack, and a Mojo `@extern` declaration has no way to mark a
  parameter as "the variadic tail," so it always uses the register
  convention. Shim size estimate: ~5-10 lines (mirrors the existing
  `mjs_ctx_call` dispatch-shim pattern already in this repo for a
  different Mojo-can't-do-this-directly case). Filed as mojito-sys#196.

Leaf-module constraint (#49/#30): **shown unnecessary for the tested
shape**. `spike/abi/ordinary_frame_test.mojo` declares raw
`mmap`/`munmap` `@extern` bindings in a module that ALSO hosts:
a `Movable` struct whose `__deinit__` calls that same extern, a raising
function with a control-flow merge before the extern call, and a
function that lowers genuine integer division AND an extern call in the
same raising body (the #30 shape) — all in the SAME module. Every check
passes; no misbind, no crash. This is a real, useful data point for
#145's audit, but NOT a blanket clearance: it covers exactly the
mmap/munmap call shape (scalar args, scalar/pointer return) tested here,
not the `mjs_*` handle-slot calling convention (`MutAnyOrigin` out-slot
pointers with the specific argument marshaling #49's original reproducer
used) or every other possible non-leaf shape. Two OTHER structural
constraints on `@extern` itself turned out to matter more than the
leaf/non-leaf distinction for THIS leg specifically:
- mojito-sys#197 — no module-level conditional compilation (a platform-
  exclusive raw symbol like `__errno_location` needs BOTH platforms'
  externs declared and a `comptime if` at the CALL site, never a runtime
  `if`, or the untaken platform fails to link/JIT); one C symbol also
  cannot be declared under two different arities in one module.
- mojito-sys#195 — `write` specifically cannot be re-declared at all
  alongside `print()`/`std.io`, regardless of leaf/non-leaf module shape.

## Defects filed (5, all with minimal reproducers under `docs/defects/`)

| Issue | One-line description |
|---|---|
| mojito-sys#194 | `SIMD[DType.uint8, N]` struct fields carry vector alignment incompatible with C byte arrays (silent correctness bug) |
| mojito-sys#195 | `@extern("write")` conflicts with `std.io`'s internal binding even with an exactly-matching signature |
| mojito-sys#196 | `ioctl`'s pointer out-parameter is silently lost (suspected Apple arm64 variadic-ABI register/stack mismatch) |
| mojito-sys#197 | no module-level conditional compilation for `@extern`; one symbol can only be declared once per module regardless of arity |
| mojito-sys#198 | no struct-alignment-override attribute (no `#pragma pack` equivalent) — feature gap, not a crash |

## Explicitly unverified / CI-pending

- Every Linux x86-64 row above: coded and believed correct (the Linux
  branches follow the same measured-not-assumed methodology as the
  macOS ones), but genuinely unverified on this host — this repo's CI
  `suite-linux` job is the first real Linux run of this suite.
- `epoll_event` AArch64 packed-vs-unpacked: **unverified anywhere
  reachable from this repo** — there is no Linux AArch64 CI lane in
  `.github/workflows/ci.yml` at all (only `suite-macos` and the x86-64
  `suite-linux`). If #145's audit needs this fact pinned down, it needs
  either a new CI lane or a manual run on real Linux AArch64 hardware;
  neither happened here.
- The mach-vs-clock_gettime epoch cross-check was removed from the test
  suite as a test-design mistake (the two clocks aren't guaranteed to
  share an epoch), not a Mojo finding — noted so it isn't mistaken for a
  silently-dropped check.
