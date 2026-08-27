# mojito-sys — Native Systems Infrastructure Implementation Specification

**Status:** Implementation specification  
**Package:** `mojito-sys`  
**Program:** Mojito systems libraries  
**Target baseline:** Mojo 1.0.0b2 public language/stdlib surface, with compatibility updates for later releases  
**Date:** 2026-08-21  
**Primary downstream consumer:** `mojito-async`

---

## 0. Executive decision

`mojito-sys` SHALL be implemented before the full `mojito-async` scheduler/runtime.

Its purpose is to establish a small, rigorously tested systems substrate between Mojo code and operating-system / machine primitives that are not yet exposed through a sufficiently stable high-level Mojo API.

The architectural boundary is:

```text
Mojo packages
    |
    v
mojito-sys public Mojo API
    |
    v
public Mojo C-FFI (`abi("C")`, `external_call`, C-compatible types)
    |
=================== C ABI FIREWALL ===================
    |
    v
small native substrate
    |
    +-- virtual memory
    +-- OS threads
    +-- TLS
    +-- native wait/wake
    +-- monotonic clocks
    +-- context switching
    +-- non-blocking sockets
    +-- readiness/completion polling
    `-- platform error translation
```

`mojito-sys` MUST NOT attempt to define or stabilize the Mojo binary ABI.

The central rule is:

> **Use the platform C ABI as the binary compatibility firewall; expose stable source-level Mojo wrappers; keep scheduler policy and concurrency semantics out of this package.**

Although `mojito-async` is the first major consumer, `mojito-sys` SHOULD be useful independently for databases, storage engines, allocators, network servers, game/runtime systems, language VMs, event loops, and other low-level Mojo software.

---

# 0A. Mandatory spike before implementation

`mojito-sys` begins with **S0: External-Stack Execution Feasibility**.

No broad infrastructure build-out should proceed until S0 establishes that ordinary Mojo frames can safely survive a native stack/context switch using only the public Mojo-to-C boundary.

**Spike decision:** `GO`, `CONDITIONAL GO`, or `NO-GO`.

See **Section 6** for the complete spike contract.

---

# 1. Motivation and current Mojo constraints

The current Mojo release provides a useful public C FFI, C-compatible primitive types, `abi("C")` function types, `external_call`, dynamic-library loading, raw pointers, atomics, and source-level ownership/origin facilities.

However, the eventual colorless concurrency runtime requires lower-level capabilities that SHOULD NOT be coupled to unstable async/runtime internals:

- arbitrary direct-style stack/context suspension;
- explicit worker OS-thread creation and joining;
- thread-local runtime state;
- virtual-address reservation and non-moving guarded stacks;
- efficient worker sleep/wake;
- non-blocking socket operations;
- epoll/kqueue/IOCP-style polling;
- monotonic clock access suitable for deadlines;
- a controlled architecture-specific assembly boundary.

`mojito-sys` exists to make those capabilities reusable and testable independently.

---

# 2. Stability policy

## 2.1 Permitted dependencies

The implementation MAY use documented public Mojo facilities for the target toolchain, including:

- `def`;
- structs, traits, generics;
- ownership and move semantics;
- origins where publicly supported;
- `UnsafePointer`;
- atomics and memory orderings;
- C-compatible types from `std.ffi`;
- `abi("C")`;
- `external_call`;
- supported dynamic/static linking;
- supported compiler sanitizers and debug tooling.

## 2.2 Prohibited dependencies

The implementation MUST NOT depend on:

- private compiler-runtime symbols;
- undocumented AsyncRT entry points;
- undocumented coroutine-frame layouts;
- internal Mojo-to-Mojo binary calling conventions across separately compiled artifacts;
- private MLIR dialect contracts;
- compiler-generated stack-frame metadata that is not a documented stable interface.

## 2.3 Compatibility promise

The primary compatibility promise is the **Mojo source API** of `mojito-sys`.

The internal C ABI used between the package and its bundled native support library MAY remain package-private until explicitly stabilized.

---

# 3. Design principles

## SYS-1 — Mechanism, not policy

`mojito-sys` exposes mechanisms:

```text
VirtualMemory.reserve()
NativeThread.spawn()
NativeTlsKey.get()
NativeEvent.wait()
NativeContext.switch()
NativeSocket.recv_nonblocking()
NativePoller.wait()
MonotonicClock.now()
```

It does not decide:

```text
which task runs next
which task owns a waiter
how cancellation propagates
how work stealing works
how a scope joins children
```

## SYS-2 — C ABI firewall

All native entry points SHALL use the platform C ABI.

## SYS-3 — Opaque native state

Prefer opaque handles or explicitly fixed C-compatible layouts instead of leaking native implementation structures into Mojo.

## SYS-4 — No hidden allocation on primitive fast paths

Clock reads, TLS reads, context switches, event signals, and similar low-level operations SHOULD be allocation-free.

## SYS-5 — Explicit blocking behavior

Every public primitive MUST document whether it may block an OS thread.

## SYS-6 — Stable addresses where required

The stack and virtual-memory APIs MUST permit users such as `mojito-async` to keep live stack addresses stable.

## SYS-7 — Platform differences remain visible where semantics genuinely differ

Do not force readiness-oriented epoll/kqueue and completion-oriented IOCP into a false identical abstraction.

---

# 4. Package structure

```text
mojito_sys/
├── __init__.mojo
├── abi/
│   ├── types.mojo
│   ├── errors.mojo
│   ├── callbacks.mojo
│   └── dynlib.mojo
├── memory/
│   ├── page.mojo
│   ├── protection.mojo
│   ├── virtual_memory.mojo
│   └── native_stack.mojo
├── thread/
│   ├── thread.mojo
│   ├── tls.mojo
│   ├── affinity.mojo
│   └── cpu_info.mojo
├── sync/
│   ├── native_mutex.mojo
│   ├── native_condvar.mojo
│   ├── native_semaphore.mojo
│   ├── native_event.mojo
│   └── atomic_wait.mojo
├── time/
│   ├── duration.mojo
│   └── monotonic.mojo
├── context/
│   ├── context.mojo
│   ├── entry.mojo
│   └── trampoline.mojo
├── io/
│   ├── handle.mojo
│   ├── socket.mojo
│   ├── poller.mojo
│   ├── readiness.mojo
│   ├── completion.mojo
│   └── platform/
│       ├── epoll.mojo
│       ├── kqueue.mojo
│       ├── iocp.mojo
│       └── io_uring.mojo
├── native/
│   ├── include/mojito_sys.h
│   ├── common/
│   ├── posix/
│   ├── windows/
│   └── arch/
│       ├── x86_64_sysv.S
│       ├── x86_64_windows.S
│       └── aarch64.S
├── test/
│   ├── abi/
│   ├── conformance/
│   ├── stress/
│   └── integration/
└── benchmark/
    ├── ffi_call.mojo
    ├── tls.mojo
    ├── thread.mojo
    ├── native_event.mojo
    ├── context_switch.mojo
    ├── vm.mojo
    ├── poller.mojo
    └── socket_loopback.mojo
```

---

# 5. Explicit non-goals

`mojito-sys` SHALL NOT implement:

- `Scope`;
- `Task`;
- `JoinHandle`;
- structured concurrency;
- work stealing;
- task cancellation;
- task-aware mutexes;
- channels;
- Futures;
- async/await adapters;
- scheduler fairness;
- task timers/timer wheels;
- high-level direct-style TCP;
- HTTP;
- actor systems;
- distributed scheduling.

Those are `mojito-async` responsibilities.

---

# 6. Phase S0 SPIKE — external-stack execution feasibility

This is a deliberately narrow **research spike and hard go/no-go gate**. It MUST be completed before broad `mojito-sys` infrastructure work and before `mojito-async` begins implementation.

The spike answers one question:

> **Can ordinary Mojo code safely execute on a `mojito-sys`-managed, non-moving native stack, suspend through a stable C-ABI context switch, and later resume with Mojo references, destructors, errors, registers, and runtime assumptions intact?**

If the answer is no, the stackful library route is not viable and the project must move toward compiler-supported one-shot suspension instead.

## 6.1 Spike hypothesis

The spike starts from the following falsifiable hypothesis:

> A Mojo function entered through an ordinary Mojo call chain can reach a tiny C-ABI context-switch shim, transfer control to a separately allocated native stack on the **same OS thread**, execute another context, and later resume the original Mojo frames without violating observable Mojo semantics or relying on private Modular runtime ABI.

The spike exists to prove or disprove this hypothesis. It is not intended to build a scheduler.

## 6.2 Spike scope

The spike SHALL implement only the minimum substrate needed for the experiment:

```text
Mojo test harness
      |
      v
minimal `NativeStack`
      |
      v
minimal `NativeContext`
      |
      v
C-ABI shim
      |
      v
one architecture-specific context switch
```

Minimum target:

- one host OS;
- one host CPU architecture;
- one OS thread;
- two synthetic execution contexts;
- reserved/committed non-moving stacks;
- no work stealing;
- no reactor;
- no task scheduler;
- no channels;
- no async/await dependency.

The first implementation SHOULD target the development host architecture that allows the shortest path to a trustworthy result.

## 6.3 Required spike prototype

The prototype MUST demonstrate this call shape:

```mojo
def level_a() raises:
    var value = ComplexValue(...)
    var original_address = __get_address_as_lvalue(value)
    level_b(value, original_address)

def level_b(ref value, original_address: UInt):
    level_c(value, original_address)

def level_c(ref value, original_address: UInt) raises:
    spike_yield_to_alternate_context()

    # Execution resumes here later on the same native stack.
    assert(__get_address_as_lvalue(value) == original_address)
    consume(value)
```

Control flow:

```text
ordinary Mojo process stack
        |
        v
level_a()
        |
        v
level_b()
        |
        v
level_c()
        |
        v
C-ABI context switch
        |
        v
alternate native stack
        |
        v
execute probe workload
        |
        v
C-ABI context switch back
        |
        v
resume exact instruction after yield
        |
        v
level_c -> level_b -> level_a
```

The alternate context MUST also be capable of yielding back and being resumed repeatedly so that the test is not merely a one-time trampoline jump.

## 6.4 Spike implementation constraints

The spike MUST:

- use only documented/public Mojo language and stdlib facilities above the C ABI;
- isolate architecture-specific code below the C ABI;
- keep both contexts on one OS thread;
- keep live stack virtual addresses stable;
- use explicitly reserved stack memory with a guard page;
- preserve the platform ABI;
- avoid current Mojo `async`, `Task`, `Task.wait()`, coroutine internals, or private compiler runtime symbols;
- avoid `ucontext` as the long-term design dependency, though it MAY be used as a disposable comparison harness if helpful;
- contain no scheduler policy.

The spike MUST NOT broaden into an FFI generator, networking layer, general threading package, or production fiber library.

## 6.5 Mandatory semantic tests

The spike is not complete until all applicable tests pass.

### S0-T1 — local-address stability

Record the addresses of stack locals before suspension and verify identical addresses after resumption.

### S0-T2 — borrowed-reference validity

Hold references to stack-backed Mojo values across the context switch and verify they remain usable after resume.

### S0-T3 — destructor exactness

Use a probe type whose destructor increments/logs a counter.

Verify:

```text
constructed once
destroyed once
not destroyed at yield
not duplicated after resume
```

### S0-T4 — `raises` after resume

Resume a suspended frame and raise an ordinary Mojo error after resumption.

Verify normal propagation through the pre-existing Mojo call chain.

### S0-T5 — `raises` before yield and cleanup

Exercise an error path before a planned yield and confirm ordinary cleanup/destruction remains correct.

### S0-T6 — repeated switching

Perform a high iteration count of:

```text
context A -> context B -> context A
```

with mutable stack-local state checked on every iteration.

### S0-T7 — nested call depth

Suspend below a configurable deep ordinary Mojo call chain and verify all frames remain intact.

### S0-T8 — integer-register preservation

Verify every ABI-required callee-saved general-purpose register.

### S0-T9 — floating/SIMD-register preservation

Verify every ABI-required floating/SIMD register that the platform ABI requires the callee to preserve.

### S0-T10 — stack alignment

Verify alignment requirements at:

- trampoline entry;
- Mojo function entry;
- after repeated switches.

### S0-T11 — TLS continuity

Verify OS-thread TLS remains unchanged across context switches.

### S0-T12 — synthetic-stack entry/exit

Create a fresh context on a new stack, enter a safe trampoline, return through the defined completion path, and reclaim the stack without corruption.

### S0-T13 — guard-page behavior

Deliberately overflow a test stack into its guard page and verify a controlled platform fault rather than silent adjacent-memory corruption.

### S0-T14 — Mojo runtime independence

Audit symbols and implementation to verify the spike does not call private Mojo async/coroutine/compiler-runtime entry points.

## 6.6 Required performance measurements

Performance is not the primary go/no-go criterion, but the spike MUST establish a baseline.

Measure at minimum:

- context switches per second;
- median context-switch latency;
- p95/p99 context-switch latency;
- cycles per switch where measurable;
- stack virtual reservation size;
- initial committed bytes;
- committed bytes after controlled stack growth;
- resident memory for 1, 100, 1,000 synthetic stacks where the host permits.

Benchmark both:

```text
A -> B -> A round trip
```

and derive/report single-switch cost clearly.

Do not claim production performance from the spike.

## 6.7 Spike deliverables

The spike SHALL produce:

1. `spike/context_switch/` source directory;
2. one architecture-specific context implementation;
3. minimal C ABI header;
4. minimal Mojo wrapper;
5. guarded native-stack allocator;
6. semantic test suite S0-T1 through S0-T14;
7. context-switch benchmark;
8. stack-memory benchmark;
9. ABI register-preservation harness;
10. `SPIKE_REPORT.md`.

`SPIKE_REPORT.md` MUST contain:

```text
Hypothesis
Environment/toolchain
Prototype architecture
Tests executed
Pass/fail matrix
Measured performance
Observed Mojo/compiler assumptions
Known limitations
Go / no-go recommendation
Required follow-up changes
```

## 6.8 Explicit pass criteria

The spike is a **GO** only if all of the following are true:

- ordinary Mojo frames resume at the correct point;
- stack-local addresses remain stable;
- borrowed stack references remain valid;
- destructors execute exactly once;
- ordinary `raises` behavior works after resume;
- repeated switching is stable;
- required registers are preserved;
- stack alignment is conformant;
- a new synthetic stack can safely enter the Mojo trampoline;
- no private Mojo runtime ABI is required;
- there is no identified compiler/runtime invariant that makes external stack switching unsound.

Performance MAY be suboptimal at this stage if the cause is understood and clearly optimizable.

## 6.9 Explicit fail criteria

The spike is a **NO-GO** for the stackful path if any of these cannot be resolved using public/stable interfaces:

- Mojo requires hidden stack metadata that cannot be reconstructed;
- live Mojo references become invalid despite non-moving stack storage;
- destructors/unwinding are unsound across suspension;
- `raises` cannot safely cross resumed frames;
- compiler-generated code assumes an OS-thread stack identity incompatible with synthetic stacks;
- correct context restoration requires private Modular runtime symbols;
- platform unwind/runtime requirements make the mechanism fundamentally non-portable for intended targets.

A performance miss alone is not a no-go unless the measured overhead defeats the project's concurrency goals and cannot plausibly be removed.

## 6.10 Decision paths

### GO

Proceed to S1 and treat the spike code as disposable evidence.

Production context and stack code MUST still be reworked to the full `mojito-sys` quality requirements.

### CONDITIONAL GO

Proceed only if the issue is bounded and a concrete mitigation exists, for example:

- debugger unwinding incomplete;
- one target architecture pending;
- stack growth policy needs redesign;
- sanitizers require custom annotations.

Document each condition in `SPIKE_REPORT.md`.

### NO-GO

Stop implementing stackful execution in `mojito-sys`.

Open a compiler/runtime design effort for a minimal public primitive equivalent to:

```text
capture/suspend one-shot continuation
resume continuation
```

Do not fall back to current thread-blocking `Task.wait()` or expose colored Future-based APIs under the same project goals.

## 6.11 Spike completion rule

S0 is complete only when the repository contains a signed-off `SPIKE_REPORT.md` with one of:

```text
GO
CONDITIONAL GO
NO-GO
```

Merely demonstrating a context switch is insufficient.

---

# 7. ABI utilities

## 7.1 C-compatible scalar types

Use `std.ffi` aliases whenever they already satisfy the requirement.

`mojito-sys` MAY re-export or normalize names for:

```text
c_char
c_short
c_int
c_long
c_long_long
c_size_t
c_ssize_t
c_pid_t
uintptr-like values
socket-length values
```

Avoid creating redundant type systems.

## 7.2 Opaque handles

Opaque native objects SHOULD cross the boundary as pointers/handles:

```mojo
struct OpaqueNativeHandle:
    var ptr: UnsafePointer[NoneType, MutUntrackedOrigin]
```

Typed wrappers own destruction.

## 7.3 Error representation

Use a compact platform-neutral error:

```mojo
struct SysError:
    var domain: ErrorDomain
    var code: Int32
```

Domains may include:

```text
POSIX_ERRNO
WIN32
WSA
MACH
INTERNAL
```

Human-readable formatting belongs off the hot path.

---

# 8. Callback ABI

Standardize the native callback shape:

```c
typedef void (*ms_callback)(void *userdata);
```

Mojo side:

```text
thin C-ABI function pointer
+
opaque userdata pointer
```

Rules:

- native code MUST NOT retain temporary Mojo pointers without an explicit lifetime contract;
- cross-thread callbacks entering Mojo MUST follow any runtime-initialization/attachment requirements documented by Mojo;
- callback ownership and destruction MUST be explicit;
- stack-borrowing callbacks MUST remain synchronous unless lifetime is statically guaranteed.

---

# 9. Virtual memory

## 9.1 API

```mojo
struct VirtualMemory:
    var base: UnsafePointer[UInt8, MutUntrackedOrigin]
    var reserved_bytes: Int
    var committed_bytes: Int

    @staticmethod
    def reserve(bytes: Int) raises -> Self:
        ...

    def commit(mut self, offset: Int, bytes: Int) raises:
        ...

    def decommit(mut self, offset: Int, bytes: Int) raises:
        ...

    def protect(
        mut self,
        offset: Int,
        bytes: Int,
        protection: Protection,
    ) raises:
        ...

    def release(mut self):
        ...
```

## 9.2 Semantics

- reservation MAY consume only virtual address space;
- commit makes pages accessible without relocation;
- decommit SHOULD release physical backing where the platform supports it;
- protection changes MUST preserve addresses;
- the page size and allocation granularity must be queryable.

## 9.3 POSIX implementation

Expected mechanisms:

```text
mmap
munmap
mprotect
madvise
sysconf
```

## 9.4 Windows implementation

Expected mechanisms:

```text
VirtualAlloc
VirtualFree
VirtualProtect
GetSystemInfo
```

---

# 10. `NativeStack`

## 10.1 Purpose

Provide a stable-address stack reservation suitable for fibers and other alternate-stack systems.

```mojo
struct NativeStack:
    var region: VirtualMemory
    var usable_low: UnsafePointer[UInt8, MutUntrackedOrigin]
    var usable_high: UnsafePointer[UInt8, MutUntrackedOrigin]
    var guard_bytes: Int

    @staticmethod
    def create(
        reserve_bytes: Int,
        initial_commit_bytes: Int,
        guard_bytes: Int,
    ) raises -> Self:
        ...

    def grow(mut self, additional_bytes: Int) raises:
        ...
```

## 10.2 Rule

**Live stack frames MUST never be moved.**

Growing by copying a live stack is prohibited.

## 10.3 Initial sizing experiment

Benchmark, do not hard-code as ABI:

```text
reserve:         2–8 MiB
initial commit:  16–64 KiB
guard:           1–2 pages
growth quantum:  16–64 KiB
```

Primary metric is committed RSS per idle fiber, not virtual reservation size.

---

# 11. Native OS threads

## 11.1 API

```mojo
struct NativeThread:
    @staticmethod
    def spawn(
        entry: CThreadEntry,
        userdata: UnsafePointer[NoneType, MutUntrackedOrigin],
        options: ThreadOptions = ThreadOptions(),
    ) raises -> Self:
        ...

    def join(mut self) raises:
        ...

    def detach(mut self) raises:
        ...

    @staticmethod
    def current_id() -> NativeThreadId:
        ...
```

## 11.2 Options

Optional:

```text
thread name
native stack size
affinity
priority hint
```

Cross-platform priority semantics MUST NOT be presented as identical.

## 11.3 POSIX

Expected:

```text
pthread_create
pthread_join
pthread_detach
pthread_self
pthread_setname_np
```

## 11.4 Windows

Use the mechanism appropriate to correct C-runtime initialization and documented Mojo integration.

---

# 12. TLS

Provide a minimal TLS key:

```mojo
struct NativeTlsKey:
    @staticmethod
    def create() raises -> Self:
        ...

    def get(self) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
        ...

    def set(
        self,
        value: UnsafePointer[NoneType, MutUntrackedOrigin],
    ) raises:
        ...

    def destroy(mut self):
        ...
```

First consumer:

```text
mojito-async current_worker
mojito-async current_task
mojito-async current_scope
```

A stable first-class Mojo TLS feature MAY replace this internally later.

---

# 13. CPU information and affinity

Provide lightweight topology information:

```mojo
struct CpuInfo:
    @staticmethod
    def logical_count() -> Int:
        ...

    @staticmethod
    def physical_count() -> Optional[Int]:
        ...
```

Optional affinity:

```mojo
struct CpuSet:
    ...

def set_current_thread_affinity(set: CpuSet) raises:
    ...
```

Topology information is advisory.

---

# 14. Native synchronization

These primitives are **OS-thread-blocking**.

Names SHALL make this distinction obvious:

```text
NativeMutex
NativeCondVar
NativeSemaphore
NativeEvent
AtomicWait
```

They exist for worker sleep/wake, native coordination, and blocking-pool infrastructure—not for application task synchronization.

---

# 15. `NativeMutex`

```mojo
struct NativeMutex:
    def lock(mut self) raises:
        ...

    def try_lock(mut self) -> Bool:
        ...

    def unlock(mut self):
        ...
```

Document:

```text
Blocking: yes, under contention
Allocation: none after initialization
Task-aware: no
```

---

# 16. `NativeCondVar`

```mojo
struct NativeCondVar:
    def wait(mut self, mutex: ref NativeMutex) raises:
        ...

    def wait_until(
        mut self,
        mutex: ref NativeMutex,
        deadline: MonotonicInstant,
    ) raises -> WaitStatus:
        ...

    def signal(mut self):
        ...

    def broadcast(mut self):
        ...
```

Timed waits use the monotonic abstraction where the OS permits it.

---

# 17. Native event/semaphore

Provide one efficient primitive suitable for waking parked OS worker threads.

Desired semantics:

```mojo
struct NativeEvent:
    def wait(mut self) raises:
        ...

    def wait_until(
        mut self,
        deadline: MonotonicInstant,
    ) raises -> WaitStatus:
        ...

    def signal(mut self):
        ...
```

The implementation MAY use semaphores, condition variables, eventfd, WaitOnAddress, or equivalent primitives.

---

# 18. Atomic wait/wake

Where stable public OS interfaces exist, expose:

```mojo
def wait_on_u32(
    address: UnsafePointer[UInt32, origin],
    expected: UInt32,
    deadline: Optional[MonotonicInstant],
) raises -> WaitStatus

def wake_one_u32(address: UnsafePointer[UInt32, origin]) -> Int
def wake_all_u32(address: UnsafePointer[UInt32, origin]) -> Int
```

Likely platform implementations:

- Linux: futex;
- Windows: WaitOnAddress/WakeByAddress;
- macOS: supported public mechanism or native-condvar fallback.

Do not depend on private kernel interfaces.

---

# 19. Monotonic clock

```mojo
struct MonotonicInstant:
    var ticks: UInt64

    @staticmethod
    def now() -> Self:
        ...

    def duration_since(self, earlier: Self) -> Duration:
        ...
```

Rules:

- scheduler deadlines MUST use monotonic time;
- wall clock is not suitable;
- conversion/calibration SHOULD avoid repeated expensive setup;
- time arithmetic must define overflow behavior.

---

# 20. `NativeContext`

## 20.1 Purpose

Provide direct machine-context switching independent of scheduling policy.

```mojo
struct NativeContext:
    @staticmethod
    def create(
        stack: ref NativeStack,
        entry: ContextEntry,
        userdata: UnsafePointer[NoneType, MutUntrackedOrigin],
    ) raises -> Self:
        ...

    @staticmethod
    def capture_current() raises -> Self:
        ...

    @staticmethod
    def switch(
        mut from_context: Self,
        mut to_context: Self,
    ):
        ...

    def destroy(mut self):
        ...
```

`switch()` MUST be allocation-free.

## 20.2 C ABI

Suggested package-internal ABI:

```c
typedef struct ms_context ms_context;
typedef void (*ms_context_entry)(void *);

size_t ms_context_size(void);
size_t ms_context_alignment(void);

int ms_context_init(
    ms_context *ctx,
    void *stack_low,
    size_t stack_size,
    ms_context_entry entry,
    void *userdata
);

void ms_context_capture(ms_context *ctx);

void ms_context_switch(
    ms_context *from,
    ms_context *to
);

void ms_context_destroy(ms_context *ctx);
```

---

# 21. Architecture-specific context requirements

Support, in order driven by user/platform demand:

1. AArch64 Darwin/Linux;
2. x86-64 System V;
3. x86-64 Windows once the Mojo target is supportable.

Each backend MUST account for:

- stack pointer;
- synthetic entry/return address;
- callee-saved GPRs;
- ABI-required vector/SIMD registers;
- stack alignment;
- red-zone rules;
- Windows shadow space where relevant;
- unwind/debug metadata where practical.

Do not oversave caller-saved registers unless the defined switch ABI requires it.

---

# 22. Synthetic context trampoline

A newly created context starts in a controlled trampoline:

```text
machine context start
        |
        v
native trampoline
        |
        v
C-ABI entry(userdata)
        |
        v
completion callback / context return handler
        |
        v
switch out permanently
```

A synthetic stack MUST never fall through an invalid return address.

---

# 23. Context conformance testing

Context-switch correctness SHALL be validated using a dedicated architecture conformance harness.

Boost.Context is the principal external reference because it is a mature cross-platform context-switching library whose `fcontext` implementation preserves stackful execution state and publishes dedicated context-switch performance measurements.

References:

- https://www.boost.org/library/latest/context/
- https://www.boost.org/doc/libs/latest/libs/context/doc/html/context/performance.html

The goal is **not** to copy Boost.Context's implementation. The goal is to ensure that `mojito-sys` tests the same classes of machine state and can be meaningfully compared against a well-established implementation.

Every architecture MUST verify preservation of:

- callee-saved integer registers;
- ABI-required vector/SIMD registers;
- stack locals;
- stack pointer alignment;
- synthetic entry/exit;
- nested context switches;
- deep call stacks;
- stack growth/commit behavior;
- repeated switching;
- Mojo destruction after resume;
- Mojo error propagation after resume;
- TLS continuity on same-thread switching;
- guard-page behavior.

Minimum stress target:

```text
>= 1,000,000 context switches
```

with invariant validation.

The architecture test harness SHOULD contain C/assembly oracle code independent of the Mojo wrapper so an ABI defect can be localized to:

```text
assembly context implementation
vs
C ABI wrapper
vs
Mojo wrapper/runtime interaction
```

## 23.1 Register sentinel test

Load ABI-preserved registers with known sentinels, switch contexts repeatedly, and verify exact restoration.

Use distinct patterns to detect register swaps.

## 23.2 Stack-local canary test

Populate stack frames with:

- integer canaries;
- floating values;
- SIMD/vector values;
- pointers to other locals;
- Mojo-owned values with destructors.

Verify after every resume.

## 23.3 Cross-implementation comparison

Where the platform supports Boost.Context, provide a benchmark/conformance binary that runs:

```text
mojito-sys NativeContext
Boost.Context fcontext
OS thread/process context baseline
```

under equivalent loop structure.

Boost's published numbers are hardware/compiler-specific and MUST NOT be treated as a universal pass/fail threshold.

---

# 24. Context benchmark

Report at minimum:

- ns/switch;
- cycles/switch;
- instructions/switch where available;
- branch misses;
- cache misses;
- compiler flags;
- architecture;
- optimization level;
- CPU affinity/pinning;
- CPU model/frequency state.

Measure:

```text
A -> B -> A round trip
```

and report both round-trip and derived single-switch cost.

Include:

1. warm-cache steady-state;
2. deliberately polluted cache working set;
3. several stack working-set sizes;
4. cold context creation separately from switch cost.

For Linux reference points, optionally run:

- `perf bench sched pipe`;
- `lmbench lat_ctx`.

These measure OS scheduler/context-switch behavior, not fiber switching, and therefore provide a useful upper-layer comparison rather than a direct equivalent.

References:

- https://man7.org/linux/man-pages/man1/perf-bench.1.html
- https://lmbench.sourceforge.net/man/lat_ctx.8.html

Maintain historical regression data, but performance gates SHALL compare baseline and candidate on the same host/session.

---

# 25. Native handles and ownership

Low-level resource wrappers SHALL make ownership explicit.

Examples:

```text
OwnedFd / BorrowedFd
OwnedSocket / BorrowedSocket
OwnedHandle / BorrowedHandle
```

Requirements:

- move transfers ownership;
- destruction closes exactly once;
- borrowed wrappers never close;
- invalid/moved-from state is detectable in debug builds.

---

# 26. Non-blocking sockets

Provide low-level non-blocking semantics only.

```mojo
struct NativeSocket:
    @staticmethod
    def tcp_v4() raises -> Self:
        ...

    def set_nonblocking(mut self, enabled: Bool) raises:
        ...

    def bind(mut self, address: SocketAddress) raises:
        ...

    def listen(mut self, backlog: Int) raises:
        ...

    def accept_nonblocking(mut self) raises -> IoAttempt[NativeSocket]:
        ...

    def recv_nonblocking(
        mut self,
        buffer: Span[UInt8],
    ) raises -> IoAttempt[Int]:
        ...

    def send_nonblocking(
        mut self,
        buffer: Span[UInt8],
    ) raises -> IoAttempt[Int]:
        ...
```

`IoAttempt` distinguishes:

```text
Ready(value)
WouldBlock
Interrupted/retry
Error
Closed/EOF where applicable
```

`mojito-sys` never parks a task.

---

# 27. Polling abstraction

## 27.1 Readiness interface

For epoll/kqueue-like systems:

```mojo
trait ReadinessPoller:
    def register(
        mut self,
        handle: NativeIoHandle,
        interests: IoInterest,
        token: UInt64,
    ) raises

    def modify(...) raises
    def unregister(...) raises

    def wait(
        mut self,
        events: Span[IoEvent],
        timeout: Optional[Duration],
    ) raises -> Int

    def wake(mut self) raises
```

`token` is completely opaque to `mojito-sys`.

## 27.2 Completion interface

Where completion semantics are materially different:

```mojo
trait CompletionPoller:
    def submit(...) raises -> SubmissionToken
    def cancel(...) raises
    def wait_completions(...) raises -> Int
    def wake(...) raises
```

Do not distort IOCP or io_uring into readiness-only abstractions if it harms correctness/performance.

---

# 28. Linux backend

Baseline:

```text
epoll
+
eventfd or equivalent explicit wake source
```

Experimental later:

```text
io_uring
```

`io_uring` MUST remain behind a capability/feature flag until:

- operation coverage is adequate;
- cancellation semantics are tested;
- kernel-version behavior is understood;
- benchmarks demonstrate benefit.

---

# 29. macOS/BSD backend

Use:

```text
kqueue
kevent
```

and a supported explicit wake mechanism.

Test EV_CLEAR/edge semantics carefully and keep them below the platform-neutral wrapper.

---

# 30. Windows backend

Use IOCP when the target platform/toolchain is supported sufficiently.

Because IOCP is completion-oriented, implement the completion interface rather than pretending it is epoll.

---

# 31. Poller correctness

Tests MUST cover:

- register;
- modify;
- unregister;
- close while registered;
- readiness racing unregister;
- explicit poller wake;
- timeout;
- many handles;
- token reuse;
- stale OS events;
- concurrent control operations if supported.

Generation checking of task identities belongs in `mojito-async`, but `mojito-sys` MUST preserve the opaque token accurately.

---

# 32. Native timers

Infrastructure requirements are deliberately minimal:

- monotonic time;
- optional native timer event source capable of waking a poller.

Do NOT implement a task timer heap/wheel here.

Possible platform mechanisms:

```text
Linux: timerfd
macOS/BSD: kqueue timers
Windows: waitable timers / suitable completion integration
```

---

# 33. Native source language

Prefer C + assembly.

Use C++ only if an unavoidable platform interface requires it.

Reasons:

- predictable C ABI;
- minimal runtime dependency;
- no exception boundary;
- easier static linking;
- easier audit.

C++ exceptions MUST NEVER cross the C ABI boundary.

---

# 34. Allocation boundaries

Rule:

> Storage must be released by the allocator/domain that created it unless the API explicitly establishes a cross-boundary allocator contract.

Do not silently mix:

```text
malloc/free
Mojo allocator
platform VM allocator
```

Opaque ownership handles simplify this.

---

# 35. Sanitizer/tooling support

CI SHOULD exercise:

```text
--sanitize=address
--sanitize=thread
```

where Mojo/platform support permits.

Native compilation SHOULD also enable:

- ASan;
- UBSan where useful;
- TSan where compatible;
- stack protector in debug/hardening builds.

Do not interpret lack of sanitizer diagnostics as proof of context-switch correctness; dedicated register/state tests remain mandatory.

---

# 36. Debugging and unwindability

Custom stacks complicate tools.

The implementation SHOULD document:

- debugger behavior;
- Linux perf stack walking;
- macOS Instruments;
- Windows ETW/profile interaction;
- crash backtrace limitations.

If architecture/platform unwind registration is needed for acceptable diagnostics, implement it as an optional native facility.

Correct execution takes priority over seamless profiler integration in S0, but production readiness requires a documented plan.

---

# 37. Performance contract

`mojito-sys` is a systems substrate; overhead must be measurable.

Fast paths SHOULD avoid:

- heap allocation;
- dynamic dispatch where static dispatch is possible;
- formatting error strings;
- global locks;
- redundant C↔Mojo crossings.

The package does not promise "zero cost" universally. It promises **thin, explicit mechanism with benchmarked overhead**.

---

# 38. Mojito Systems Validation Suite (MSVS)

`mojito-sys` SHALL maintain a dedicated **Mojito Systems Validation Suite (MSVS)**.

The systems substrate crosses calling conventions, operating-system APIs, memory protection, threads, machine context, polling APIs, and architecture-specific assembly. Ordinary unit tests are insufficient.

MSVS SHALL combine:

```text
ABI conformance
platform API conformance
context/register conformance
concurrency stress
I/O backend regression
sanitizers
fault injection
microbenchmarks
cross-platform qualification
```

## 38.1 External reference suites

### libffi testsuite — ABI/calling-convention reference

libffi exists specifically to bridge compiler calling conventions across many architectures and contains a substantial testsuite covering calls, closures/callbacks, structs, return types, and ABI-specific cases.

Reference:

- https://github.com/libffi/libffi
- https://github.com/libffi/libffi/tree/master/testsuite

MSVS SHALL borrow its **signature-matrix approach**.

Do not copy test source without a license review; generate Mojito-specific ABI cases.

### Boost.Context — machine-context reference

Boost.Context is the primary reference for:

- stackful context semantics;
- architecture-specific context state;
- context-switch microbenchmarks.

Reference:

- https://www.boost.org/library/latest/context/
- https://www.boost.org/doc/libs/latest/libs/context/doc/html/context/performance.html

### Linux Test Project (LTP) — kernel/POSIX environment qualification

LTP provides a large collection of tests intended to validate Linux kernel reliability, robustness, stability, syscalls, and related system-library behavior.

Reference:

- https://github.com/linux-test-project/ltp

MSVS SHALL use selected LTP results to qualify the Linux host/kernel when investigating failures in:

- memory mapping;
- threads;
- futexes/synchronization;
- timers/clocks;
- sockets;
- epoll/syscalls.

`mojito-sys` does not need to vendor or rerun all LTP tests in every PR.

### liburing regression suite — `io_uring` environment qualification

The liburing project states that much of its repository is regression/unit tests for both liburing and kernel `io_uring` support.

Reference:

- https://github.com/axboe/liburing

Before declaring a `mojito-sys` `io_uring` backend defect on a particular kernel, record the relevant liburing regression result where practical.

### LLVM sanitizers

ThreadSanitizer detects data races through compiler instrumentation/runtime support; Clang documents typical substantial runtime and memory overhead, so it belongs in correctness CI rather than performance measurement.

Reference:

- https://clang.llvm.org/docs/ThreadSanitizer.html

Native shim code SHOULD be exercised under:

- ASan;
- UBSan;
- TSan where compatible;
- leak detection.

### Linux `perf bench` and lmbench

Linux `perf bench` provides scheduler, futex, epoll, syscall and memory benchmarks; lmbench includes context-switch and system-latency benchmarks.

References:

- https://man7.org/linux/man-pages/man1/perf-bench.1.html
- https://lmbench.sourceforge.net/man/lmbench.8.html
- https://lmbench.sourceforge.net/man/lat_ctx.8.html

These are host/system comparison points, not replacements for Mojito-specific microbenchmarks.

## 38.2 MSVS suite layout

Recommended:

```text
validation/
├── abi/
├── vm/
├── thread/
├── sync/
├── context/
├── poller/
├── socket/
├── time/
├── sanitizer/
├── fault/
├── benchmark/
└── platform/
```

---

## 38.3 ABI conformance suite

The ABI suite SHALL validate the **actual Mojo ↔ C boundary** used by `mojito-sys`.

### 38.3.1 Generated signature matrix

Build a generator that emits:

```text
C oracle function
+
matching Mojo declaration/caller
+
expected value checks
```

for combinations of:

- signed/unsigned integers: 8/16/32/64-bit;
- pointer-sized integer types;
- `Bool`/C boolean representation where supported;
- `float`;
- `double`;
- pointers;
- function pointers;
- enums with explicitly controlled representation where applicable;
- structs by value;
- struct returns;
- mixed integer/floating structs;
- nested structs;
- alignment/padding cases;
- arrays inside structs where ABI-supported;
- variadic calls with required default promotions;
- callbacks C → Mojo;
- callback round trip Mojo → C → Mojo;
- zero/one/many arguments;
- register-to-stack argument spill boundaries.

### 38.3.2 Struct-size boundary corpus

ABI defects often appear at register classification boundaries.

Generate struct sizes around important boundaries, for example:

```text
1, 2, 3, 4, 7, 8, 9,
15, 16, 17,
23, 24, 25,
31, 32, 33,
48, 64, 80, 96, 128, 256 bytes
```

Use differing field compositions, not only byte arrays.

### 38.3.3 Mixed register-class cases

Generate signatures with enough mixed integer/floating arguments to cross:

```text
GPR register budget
FPR/SIMD register budget
stack spill boundary
```

This is specifically inspired by the kinds of ABI edge cases covered in libffi's testsuite.

### 38.3.4 Callback lifetime tests

Test:

- synchronous callback;
- repeated callback;
- callback with opaque userdata;
- callback on a C-created worker thread if supported;
- callback returning structs/scalars;
- callback error handling boundary.

Never let a callback outlive Mojo-owned state unless the API explicitly transfers/extends ownership.

### 38.3.5 Dynamic symbol tests

Where dynamic loading is supported, validate:

- symbol found;
- missing symbol;
- library unload ownership;
- function pointer invocation;
- platform error retrieval.

---

## 38.4 Virtual-memory conformance suite

Required tests:

- reserve;
- commit;
- decommit;
- release;
- protect read-only;
- protect no-access;
- guard page;
- alignment;
- page-size query;
- large reservation;
- partial commit;
- repeated commit/decommit;
- address stability;
- failure/error translation;
- resource cleanup.

Fault tests SHOULD deliberately access a guard/no-access page in an isolated child process so the test runner survives.

---

## 38.5 Thread/TLS/synchronization conformance

Test:

### Threads

- create;
- join;
- many sequential creates;
- many concurrent creates;
- thread return value/error;
- worker entry trampoline;
- native thread IDs;
- shutdown.

### TLS

- per-thread isolation;
- set/get;
- destructor if supported;
- repeated thread reuse;
- same-thread context switching retains the same TLS value.

### Native synchronization

- uncontended mutex;
- contended mutex;
- condition/event wake-one;
- wake-all;
- semaphore permit accounting;
- wake-before-wait race;
- timeout;
- EINTR/spurious wake behavior where applicable;
- destruction only after waiters have exited.

Include high-iteration actor/outcome stress for wake/wait races, borrowing the `jcstress` methodology even though the implementation language differs.

---

## 38.6 Context conformance suite

Section 23 defines the minimum architecture harness.

MSVS additionally requires:

- independent C/assembly-only context test;
- Mojo-on-synthetic-stack test;
- 1M+ switch stress;
- deep recursive frames;
- varying stack working sets;
- destructor/error tests;
- TLS continuity;
- sanitizer/tooling compatibility where possible;
- cross-implementation comparison against Boost.Context where available.

A platform is not `NativeContext`-supported until this suite passes.

---

## 38.7 Poller conformance suite

Each backend must pass a common semantic suite plus backend-specific tests.

### Common semantic cases

- register readable handle;
- register writable handle;
- timeout with no events;
- immediate readiness;
- multiple ready handles;
- unregister;
- close while registered;
- close followed by descriptor/handle reuse;
- duplicate registration behavior;
- event token/data round trip;
- interrupt/retry;
- error/hangup;
- EOF;
- 1k/10k/100k registrations where platform limits permit;
- concurrent registration from supported threads;
- poller destruction.

### epoll-specific

Test:

- level-triggered mode;
- edge-triggered mode if exposed;
- one-shot if exposed;
- `EPOLLHUP`;
- `EPOLLERR`;
- fd reuse hazards.

### kqueue-specific

Test equivalent filter lifecycle and EOF/error cases.

### IOCP-specific

Test:

- overlapped operation lifecycle;
- completion key/token integrity;
- close/cancel completion behavior.

### io_uring-specific

Test:

- feature detection;
- queue-full behavior;
- submission/completion token generation;
- cancellation;
- supported operation matrix;
- stale completion defense.

Record kernel version and relevant liburing regression state.

---

## 38.8 Socket conformance suite

Test wrapper semantics independent of `mojito-async`:

- create;
- bind;
- listen;
- connect;
- accept;
- non-blocking configuration;
- send/recv;
- shutdown;
- close;
- address conversion;
- IPv4;
- IPv6 where available;
- Unix-domain sockets where supported;
- connection refusal;
- peer reset;
- EOF;
- descriptor ownership and double-close prevention.

Use loopback/local fixtures only in ordinary CI.

---

## 38.9 Time conformance suite

Test:

- monotonicity;
- conversion overflow boundaries;
- sleep/wait timeout behavior;
- resolution reporting;
- duration arithmetic;
- large elapsed intervals using mocked wrapper math where practical.

Never infer monotonic behavior from wall-clock time.

---

## 38.10 Sanitizer and hardening matrix

Native C/assembly helpers SHOULD be built in multiple modes:

```text
release optimized
debug assertions
ASan
UBSan
TSan where compatible
stack protector
FORTIFY where applicable
```

Assembly/context code may require sanitizer annotations or separate harnesses.

Any exclusion from sanitizer instrumentation MUST be:

- narrow;
- documented;
- justified by the mechanism rather than used to hide reports.

---

## 38.11 Fault injection

Inject or simulate:

- allocation failure;
- `mmap`/`VirtualAlloc` failure;
- thread creation failure;
- TLS allocation failure;
- EINTR;
- EAGAIN;
- descriptor exhaustion;
- poller creation failure;
- poll registration failure;
- clock/query failure where the platform allows;
- partial I/O;
- unsupported kernel feature.

The wrapper must return/raise deterministic errors and must not leak partially created resources.

---

## 38.12 Performance benchmark methodology

Use a baseline-vs-candidate harness.

Record:

```text
CPU
architecture
OS/kernel
Mojo toolchain
native compiler
optimization flags
CPU affinity
frequency/governor
raw samples
```

Warm up before measuring steady-state mechanisms.

Repeat measurements and retain raw samples.

Use dedicated hardware for release performance qualification where possible.

Do not benchmark sanitizer builds.

### ABI benchmarks

- direct C function call baseline;
- Mojo `external_call`;
- thin C function-pointer call;
- C callback;
- Mojo → C → Mojo callback;
- struct by-value call at representative sizes.

The important metric is **incremental boundary overhead over equivalent direct native C**.

### Memory benchmarks

- reserve;
- commit;
- decommit;
- protect;
- release;
- large sparse reservation;
- stack reserve/initial commit.

### Threading benchmarks

- thread create/join;
- TLS get/set;
- NativeEvent ping-pong;
- NativeMutex uncontended;
- NativeMutex contended;
- wake-one/wake-all.

### Context benchmarks

- context create/destroy;
- A ↔ B switch;
- stack growth/commit;
- switch with increasing stack working-set/cache pressure.

Comparison references:

```text
Boost.Context fcontext
perf bench sched pipe
lmbench lat_ctx
```

Interpret them according to semantics: OS context-switch benchmarks are not expected to match fiber switches.

### Poller benchmarks

- create/destroy;
- add/delete/modify registration;
- empty wait;
- one ready handle;
- readiness storm;
- 1k/10k/100k registered handles;
- cross-thread wake mechanism;
- token decode/dispatch.

### Socket benchmarks

- loopback connection setup;
- ping-pong latency;
- throughput by payload size;
- many idle sockets.

## 38.13 Performance statistics and regression gates

Every performance result should include enough samples to quantify noise.

Report as applicable:

- median;
- mean;
- standard deviation/confidence interval;
- p95/p99 for latency distributions;
- ns/op;
- cycles/op;
- instructions/op;
- ops/s;
- RSS;
- page faults;
- context switches.

A regression gate MUST be calibrated per benchmark from observed variance rather than using one universal threshold.

---

## 38.14 Cross-platform/compiler matrix

At minimum, every supported release configuration should identify:

```text
Mojo version
OS
architecture
native C/assembly compiler
linker
optimization mode
```

Native code SHOULD be tested with at least the principal supported compiler for that platform.

Where practical on Linux/macOS, test native shim compilation with both Clang and GCC to expose non-portable extensions.

ABI tests MUST run on every architecture claimed as supported; cross-compilation alone is insufficient.

---

## 38.15 CI tiers

### SYS Tier 0 — developer

- focused unit/conformance;
- ABI smoke set;
- context-switch smoke;
- wrapper compile checks.

### SYS Tier 1 — every PR

- full generated ABI matrix at bounded size;
- VM/thread/TLS/sync tests;
- context conformance;
- poller/socket integration;
- fault-injection smoke;
- sanitizer subset;
- benchmark compile + selected performance smoke.

### SYS Tier 2 — nightly

- expanded/generated ABI corpus;
- high-iteration context stress;
- actor/outcome synchronization stress;
- full sanitizers;
- 100k-handle poller tests where host permits;
- Linux environment qualification subsets;
- full microbenchmark suite.

### SYS Tier 3 — weekly/release

- all supported OS/architecture combinations;
- long resource-leak stress;
- dedicated-hardware performance A/B;
- Boost.Context comparison;
- perf/lmbench comparison on Linux;
- relevant LTP qualification;
- liburing regression qualification where `io_uring` is shipped.

---

## 38.16 Machine-readable results

MSVS SHOULD emit a common JSON Lines schema.

Example:

```json
{
  "suite": "abi",
  "test": "struct_return/24B/mixed_fp_int",
  "platform": "linux-x86_64",
  "mojo": "1.x",
  "result": "PASS"
}
```

Benchmark example:

```json
{
  "suite": "benchmark",
  "test": "context_switch",
  "platform": "linux-x86_64",
  "iterations": 1000000,
  "median_ns_per_switch": 12.4,
  "cycles_per_switch": 31.8
}
```

This allows continuous dashboards and cross-version trend analysis.

---

## 38.17 Release-support gate

A platform/architecture SHALL NOT be advertised as supported until:

```text
ABI conformance       PASS
VM conformance        PASS
thread/TLS/sync       PASS
NativeContext         PASS, if offered
poller/socket         PASS, if offered
sanitizer gate        PASS or documented tool limitation
resource-leak stress  PASS
performance review    complete
```

For Linux `io_uring`, also record the supported kernel feature floor and the liburing regression status used during qualification.

---

# 39. API documentation format

Every primitive SHOULD document:

```text
Blocking:
Allocates:
Thread-safe:
Reentrant:
Signal-safe:
Ownership:
Platform notes:
Stability:
```

Example:

```text
NativeContext.switch
Blocking: no
Allocates: no
Thread-safe: context objects are externally synchronized
Reentrant: only according to context ownership rules
Signal-safe: no guarantee
Ownership: caller retains both contexts
Stability: experimental
```

---

# 40. Implementation phase S1 — ABI + VM foundation

Deliver:

- project build layout;
- bundled native library linking;
- C-compatible error representation;
- page-size query;
- `VirtualMemory`;
- `NativeStack`;
- ABI conformance tests;
- guarded stack tests.

Exit criteria:

- reservation/commit/decommit/protection pass on primary targets;
- no live-stack relocation mechanism exists;
- ABI size/alignment tests pass.

---

# 41. Phase S2 — threads + TLS

Deliver:

- `NativeThread`;
- join/detach;
- thread names;
- `NativeTlsKey`;
- CPU count;
- optional affinity;
- lifecycle stress tests.

Exit criteria:

- a downstream library can create N workers and store a worker pointer in TLS without private Mojo runtime APIs.

---

# 42. Phase S3 — native wait/wake + time

Deliver:

- `NativeMutex`;
- `NativeCondVar`;
- `NativeEvent`/semaphore;
- atomic wait/wake where justified;
- monotonic clock;
- timed waits.

Exit criteria:

- worker threads can efficiently sleep and be awakened from other workers/reactor control paths.

---

# 43. Phase S4 — production context support

Deliver:

- production-quality AArch64 implementation;
- production-quality x86-64 SysV implementation;
- additional target ABIs as supported;
- context conformance suite;
- stack-growth policy;
- benchmark regression gate;
- debug/unwind documentation.

Exit criteria:

- stack switching is reliable enough to be treated as a dependency, not an experiment.

---

# 44. Phase S5 — sockets + pollers

Deliver:

- native socket ownership;
- non-blocking networking;
- epoll;
- kqueue;
- poller wake;
- completion interface design;
- IOCP when feasible;
- io_uring experimental backend.

Exit criteria:

- a downstream reactor can multiplex many connections without blocking OS worker threads.

---

# 45. Phase S6 — production hardening

Deliver:

- cross-platform CI matrix;
- sanitizers;
- benchmark tracking;
- stability annotations;
- API docs;
- native source audit;
- failure injection;
- packaging/distribution.

Exit criteria:

- `mojito-sys` can be versioned as an independent dependency of `mojito-async`.

---

# 46. Handoff gate to `mojito-async`

The full `mojito-async` runtime SHALL NOT pass its prototype stage until all applicable items are checked:

- [ ] ordinary Mojo frames survive context switch/resume;
- [ ] stack-local Mojo references remain valid;
- [ ] destructors execute exactly once after suspension/resume;
- [ ] Mojo `raises` behavior has been validated after resume;
- [ ] NativeThread supports worker creation/join;
- [ ] NativeTlsKey supports current-worker/current-task storage;
- [ ] worker sleep/wake is efficient;
- [ ] monotonic deadlines are reliable;
- [ ] guarded non-moving stacks are implemented;
- [ ] NativeContext is allocation-free on switch;
- [ ] non-blocking sockets are implemented;
- [ ] at least one production primary-platform poller is implemented;
- [ ] poller explicit wake works;
- [ ] no private compiler-runtime dependency exists;
- [ ] ABI/register conformance tests run in CI;
- [ ] context performance meets the agreed baseline;
- [ ] native memory/synchronization stress tests pass.

---

# 47. Dependency contract exposed to `mojito-async`

`mojito-async` should need approximately this systems surface:

```text
mojito_sys.memory.NativeStack
mojito_sys.context.NativeContext
mojito_sys.thread.NativeThread
mojito_sys.thread.NativeTlsKey
mojito_sys.sync.NativeEvent
mojito_sys.time.MonotonicInstant
mojito_sys.io.NativeSocket
mojito_sys.io.ReadinessPoller / CompletionPoller
```

The concurrency package SHALL NOT directly call:

```text
pthread_*
mmap
mprotect
epoll_*
kevent
IOCP APIs
assembly context-switch symbols
platform TLS APIs
```

---

# 48. Repository epics

## Epic SYS-A — S0 external-stack feasibility spike
- SYS-A0.1 define spike hypothesis and host target
- SYS-A0.2 minimal guarded synthetic stack allocation
- SYS-A0.3 one-architecture C-ABI context switch
- SYS-A0.4 repeated A↔B switching harness
- SYS-A0.5 Mojo deep-frame resume + address-stability tests
- SYS-A0.6 borrowed-reference validity tests
- SYS-A0.7 destructor and `raises` tests
- SYS-A0.8 integer/SIMD register preservation harness
- SYS-A0.9 stack-alignment/TLS/trampoline tests
- SYS-A0.10 guard-page failure test
- SYS-A0.11 context-switch + stack-memory benchmarks
- SYS-A0.12 private-runtime dependency audit
- SYS-A0.13 `SPIKE_REPORT.md` with GO / CONDITIONAL GO / NO-GO

## Epic SYS-B — ABI
- SYS-B1 C type conformance
- SYS-B2 error domains
- SYS-B3 callback conventions
- SYS-B4 opaque-handle utilities
- SYS-B5 linking/packaging harness

## Epic SYS-C — memory
- SYS-C1 page query
- SYS-C2 reserve/release
- SYS-C3 commit/decommit
- SYS-C4 protection
- SYS-C5 NativeStack
- SYS-C6 guard tests

## Epic SYS-D — thread
- SYS-D1 thread create/join
- SYS-D2 names
- SYS-D3 TLS
- SYS-D4 CPU topology
- SYS-D5 affinity
- SYS-D6 lifecycle stress

## Epic SYS-E — synchronization/time
- SYS-E1 mutex
- SYS-E2 condvar
- SYS-E3 native event/semaphore
- SYS-E4 monotonic clock
- SYS-E5 timed wait
- SYS-E6 atomic wait/wake research

## Epic SYS-F — context
- SYS-F1 AArch64
- SYS-F2 x86-64 SysV
- SYS-F3 Windows x64
- SYS-F4 conformance
- SYS-F5 stack growth
- SYS-F6 profiler/debug notes

## Epic SYS-G — I/O
- SYS-G1 socket ownership
- SYS-G2 non-blocking socket ops
- SYS-G3 epoll
- SYS-G4 kqueue
- SYS-G5 poller wake
- SYS-G6 IOCP
- SYS-G7 io_uring experiment
- SYS-G8 scale benchmarks

## Epic SYS-H — hardening
- SYS-H1 CI matrix
- SYS-H2 sanitizer runs
- SYS-H3 benchmark regression
- SYS-H4 API stability markers
- SYS-H5 docs
- SYS-H6 native audit

---

# 49. ADRs

## ADR-SYS-001 — Name

**Decision:** `mojito-sys`.  
**Reason:** establishes the Mojito family and accurately describes a reusable systems substrate.

## ADR-SYS-002 — C ABI firewall

**Decision:** native boundary uses C ABI.  
**Reason:** avoid depending on an unstable Mojo binary ABI.

## ADR-SYS-003 — Context switching belongs here

**Decision:** machine context/alternate stacks are infrastructure, not scheduler policy.  
**Reason:** reuse, isolated testing, architecture encapsulation.

## ADR-SYS-004 — No scheduler policy

**Decision:** no task/scope/channel implementation in `mojito-sys`.  
**Reason:** strict dependency boundary.

## ADR-SYS-005 — Stable-address stacks

**Decision:** reserve/commit; never copy live stacks.  
**Reason:** preserve stack-backed Mojo references.

## ADR-SYS-006 — OS-thread-blocking types are explicit

**Decision:** use `Native*` terminology.  
**Reason:** distinguish them from `mojito-async` task-aware primitives.

## ADR-SYS-007 — Polling abstraction may have readiness and completion variants

**Decision:** do not force platform models into one lossy interface.  
**Reason:** epoll/kqueue and IOCP/io_uring differ materially.

## ADR-SYS-008 — Feasibility before breadth

**Decision:** S0 precedes broad infrastructure implementation.  
**Reason:** external stack switching is the critical dependency.

---

# 50. Open questions

1. Which public Mojo release/toolchain should define the first support floor?
2. What is the minimal native shim after auditing current stdlib coverage?
3. Does Mojo require runtime attachment when C-created worker threads call Mojo entry points?
4. Which callable/C-ABI signature is safest for worker/context entry trampolines?
5. Can context objects live inline in Mojo storage without layout hazards, or should native handles remain opaque?
6. What profiler/unwinder integration is needed for alternate stacks?
7. What stack-growth mechanism is portable without unsafe signal-handler complexity?
8. Should macOS stack reservation follow different guard/growth defaults than Linux?
9. How should Windows support be staged relative to Mojo's own target support?
10. Should `io_uring` be a separate optional package/backend?
11. Which low-level primitives are already stable enough in Mojo stdlib that wrapping them would add no value?
12. Should the package include basic process primitives later, or keep its initial scope narrowly targeted?

---

# 51. Acceptance definition

`mojito-sys` succeeds if a downstream runtime can implement a fiber scheduler and reactor entirely in Mojo while treating the following as stable source-level mechanisms:

```text
allocate non-moving guarded stack
create native execution context
switch context
create/join worker thread
store/retrieve TLS pointer
sleep/wake worker
read monotonic time
create non-blocking socket
poll many native I/O handles
```

with no direct platform calls in the downstream runtime.

---

# 52. Source references

Current Mojo documentation relevant to the implementation:

- Mojo releases: https://mojolang.org/releases/
- Mojo FFI: https://mojolang.org/docs/std/ffi/
- Mojo function declarations / `abi("C")`: https://mojolang.org/docs/reference/function-declarations/
- Mojo system package: https://mojolang.org/docs/std/sys/
- Mojo CLI sanitizer/debug options: https://mojolang.org/docs/cli/build/

### External validation references

- libffi and its ABI testsuite: https://github.com/libffi/libffi
- Boost.Context: https://www.boost.org/library/latest/context/
- Boost.Context performance reference: https://www.boost.org/doc/libs/latest/libs/context/doc/html/context/performance.html
- Linux Test Project: https://github.com/linux-test-project/ltp
- liburing regression suite: https://github.com/axboe/liburing
- Clang ThreadSanitizer: https://clang.llvm.org/docs/ThreadSanitizer.html
- Linux `perf bench`: https://man7.org/linux/man-pages/man1/perf-bench.1.html
- lmbench: https://lmbench.sourceforge.net/man/lmbench.8.html
- lmbench `lat_ctx`: https://lmbench.sourceforge.net/man/lat_ctx.8.html
- OpenJDK `jcstress` (actor/outcome stress methodology): https://openjdk.org/projects/code-tools/jcstress/
- OpenJDK JMH (benchmark harness methodology): https://openjdk.org/projects/code-tools/jmh/
- Go performance monitoring (baseline-vs-experiment methodology): https://go.dev/wiki/PerformanceMonitoring

The project should track the current Mojo release documentation continuously because the boundary between standard-library capability and `mojito-sys` responsibility is expected to move.

---

# 53. Final architecture

```text
                 Higher-level Mojo systems libraries
                           |
                 .---------+---------.
                 |                   |
                 v                   v
           mojito-async        future runtimes
                 |                   |
                 '---------+---------'
                           |
                           v
                   +---------------+
                   |  mojito-sys   |
                   |---------------|
                   | VirtualMemory |
                   | NativeStack   |
                   | NativeContext |
                   | NativeThread  |
                   | NativeTLS     |
                   | NativeEvent   |
                   | MonotonicTime |
                   | NativeSocket  |
                   | Poller        |
                   +-------+-------+
                           |
===================== C ABI firewall =====================
                           |
             .-------------+-------------.
             |             |             |
             v             v             v
          libc/OS       kernel APIs    assembly
```

`mojito-sys` should remain intentionally boring at the semantic level. Its value is that the mechanisms are **correct, fast, portable, audited, benchmarked, and independent of unstable Mojo runtime internals**.

# 55. S5.7 stack-growth policy — decision record (issue #70)

**Status:** RULED (5-expert adversarial panel: Architecture / mojo+Clang
Systems / Safety+Reliability / API Design / OS-kernel). **Applies to:**
NativeContext reservations (epic S5), consistent with S1 NativeStack.

**Policy.** A NativeContext stack reservation is a FIXED interval
`[stack_low, stack_low+stack_size)` with NO automatic growth and NO
relocation (ADR-SYS-005). The stack grows top-down over the range the
OWNER has committed (mjs_stack_alloc paints a PROT_NONE guard page below
the usable floor and returns guard_low; the owner commits more span via
mjs_vm_commit). Crossing the floor faults synchronously at the offending
store (SIGBUS on macOS/arm64, SIGSEGV on Linux) — the MMU is the ONLY
mechanism that can catch an overflow that happens BETWEEN switch points;
a software sp check at the next save runs AFTER the corrupting write and
can diagnose but never prevent.

**Enforcement split (no ABI change; record stays 200 bytes; the v3
lifecycle tail @168-199 remains fully allocated to the state machine).**
- ms_context_init: rejects stack_top wrap (stack_low + size fold) with
  -EINVAL; keeps 16-alignment and NULL checks (frozen).
- Switch backend: traps (brk #0x6b) on a restored sp that is not
  16-aligned (AAPCS64), BEFORE sp goes live — a poisoned record cannot
  resume into a wild stack pointer.
- OWNER (mojito-async dispatcher): validates the saved sp slot (@160)
  against its own guard_low/top before switching; treats a guard fault
  as a fatal, diagnosable task error (never corruption).
- Unguarded static-buffer reservations stay accepted for tests/compat;
  overflow on them is documented caller error.

**Must-not-do (panel).** Grow the record 200→216 (frozen ABI, caller
visible); store bounds in the v3 tail (no free slot); mprotect caller-
provided storage from the library (ownership + partial-page collateral);
add a library allocation/ownership API (SYS-4, second ownership regime);
per-switch software sp-vs-floor checks as enforcement (cannot prevent);
SIGSEGV-handler soft growth (hidden allocation); test with fixed
recursion counts (frame size varies with -O level — depth must be a
derived result).
