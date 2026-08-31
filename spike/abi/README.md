# M1.2 spike — ABI: C struct layout and direct libc/OS calls from Mojo

Part of the Mojo-first migration's Phase 1 spike (epic #121, spec §6). This
leg proves both ends of the raw ABI edge for issue #124: Mojo describes the
operating system's C structs byte-exactly, and Mojo calls the operating
system directly, with no C wrapper anywhere in the chain. Contract source
of truth: `docs/mojito-sys_MOJO_MIGRATION_SPEC.md` §2.1, §6, §8.

## Question

Can Mojo 1.0.0b2 declare the OS-struct inventory from #122 (`timespec`,
`timeval`, `sockaddr_in`/`in6`/`un`, `iovec`, `kevent`/`epoll_event`,
opaque `pthread_attr_t`/`pthread_mutex_t`) with size/alignment/field
offsets that match a live C oracle exactly, pass/return them by value and
by pointer correctly, and call libc/the OS directly (`mmap`/`munmap`/
`mprotect`/page size, `clock_gettime`/`mach_absolute_time`, `socket`/
`close`/`read`/`write`/`recv`/`send`, plus the variadic/macro-shaped
`fcntl`/`open`/`ioctl`) from an ordinary (non-leaf) Mojo frame, with
`errno` read correctly?

## Scope

```text
spike/abi/oracle.c              the C oracle: struct fill/check/size/
                                 align/offset getters, and libc-call
                                 helpers that make the identical call
                                 Mojo is about to make, for comparison
spike/abi/types.mojo             Mojo struct declarations (production-like,
                                 no @extern)
spike/abi/externs_leaf.mojo      pure LEAF module: @extern bindings for
                                 oracle.c + raw libc/OS calls, plus
                                 non-raising probe_* shims (repo
                                 convention, precedent #49)
spike/abi/struct_layout_test.mojo   struct-layout half: static layout +
                                     byte-pattern round trip (both
                                     directions) + by-value/by-pointer
                                     argument passing
spike/abi/libc_calls_test.mojo      libc-call half: direct calls diffed
                                     against the oracle's own identical
                                     call, 3 distinct errno failure
                                     modes, variadic/macro entry points
spike/abi/ordinary_frame_test.mojo  the leaf-module-constraint probe:
                                     the SAME libc calls from a module
                                     that ALSO hosts a Movable struct,
                                     a raising function, a control-flow
                                     merge, and integer division — the
                                     exact #49/#30 trigger shape
docs/defects/*.mojo               minimal reproducers for every Mojo
                                   compiler defect/gap this leg hit
```

One host so far: macOS arm64 (Darwin 25.6.0), Mojo 1.0.0b2 (2cf4d08a),
homebrew mojolang tap. Linux x86-64 signal comes from this repo's CI
`suite-linux` job; **no Linux aarch64 CI lane exists in this repo at
all**, so the AArch64-vs-x86-64 `epoll_event` packing divergence issue
#124 specifically calls out stays unverified anywhere reachable from
this repo, not just on this host — flagged, not guessed at.

## What's proven, measured on macOS arm64 (see FINDINGS.md for detail)

- Every struct in scope: size + every field offset match the C oracle
  exactly, in both directions (C fills → Mojo reads typed fields; Mojo
  fills → C reads through the real struct), for `timespec`, `timeval`,
  `sockaddr_in`, `sockaddr_in6`, `sockaddr_un` (+ `sa_family_t`/
  `socklen_t` scalars), `iovec`, `kevent`, and the opaque
  `pthread_attr_t`/`pthread_mutex_t` blobs (round-tripped through a REAL
  `pthread_attr_init`/`pthread_mutex_init`/lock/unlock/destroy cycle, not
  just measured).
- By-value argument passing AND by-value struct return both work for
  `timespec` (register-pair sized); by-pointer both directions work for
  the bigger structs.
- Direct, unwrapped calls to `sysconf`, `mmap`/`munmap`/`mprotect`,
  `clock_gettime(CLOCK_MONOTONIC)`, `mach_absolute_time` +
  `mach_timebase_info`, `socket`/`close`/`read`/`recv`/`send` (`write`
  via `std.io.FileDescriptor` — see defect mojito-sys#195), all diffed
  against the oracle's own identical call.
- `errno` read correctly via the platform's REAL accessor function
  (`__error()` on macOS; `__errno_location()` declared for Linux, CI-
  pending) across three distinct, deliberately-triggered failure modes:
  EBADF, EINVAL, EAGAIN.
- `fcntl` and `open` reachable via fixed-arity declarations, both 2-arg
  and 3-arg call shapes, values verified to actually reach the real
  syscall (not just "returned 0"). `ioctl`'s pointer-out-parameter form
  is NOT reachable this way — mojito-sys#196.
- The leaf-module constraint from #49/#30 does NOT reproduce for raw
  libc calls (mmap/munmap) in a module that also hosts a Movable struct
  with a destructor calling that same extern, a raising function, a
  control-flow merge, and integer division in the same frame — a real,
  useful data point for #145, though not a blanket clearance (see
  FINDINGS.md for the scope of what this does and doesn't cover).

## Compiler defects/gaps found and filed

Five, each with a minimal reproducer under `docs/defects/` and filed
against this repo:

- mojito-sys#194 — `SIMD[DType.uint8, N]` struct fields carry vector
  alignment incompatible with C byte arrays (silent correctness bug).
- mojito-sys#195 — `@extern("write")` conflicts with `std.io`'s internal
  binding even with an exactly-matching signature.
- mojito-sys#196 — `ioctl`'s pointer out-parameter is silently lost
  (suspected Apple arm64 variadic-ABI register/stack mismatch).
- mojito-sys#197 — no module-level conditional compilation for
  `@extern`; one symbol can only be declared once per module regardless
  of arity.
- mojito-sys#198 — no struct-alignment-override attribute (no
  `#pragma pack` equivalent) — feature gap, not a crash.

## Running the suite

```sh
cd spike/abi
./run.sh
```

or from the repo root: `MOJO=mojo CC=cc spike/abi/run.sh`.

## Deliverables

`spike/abi/` sources (oracle + Mojo declarations + three test files),
`docs/defects/` reproducers, this README, `FINDINGS.md` (measured
results, acceptance-criteria checklist, what's CI-pending/unverified).
