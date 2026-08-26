# mojito-sys S2.2 — NativeThread + ThreadOptions (issue #49).
#
# Spec §11 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s2-thread block):
#   mjs_thread_spawn(entry, userdata, stack_size, name, out) — joinable
#     handle; name applied inside the child's trampoline;
#   mjs_thread_join(t**, out_result)  — BLOCKS; stores entry status; NULLs
#     *t on success;
#   mjs_thread_detach(t**)            — non-blocking; NULLs *t on success;
#   mjs_thread_self_id()              — calling thread's raw id;
#   mjs_thread_set_name(name)         — CALLING thread's name.
#
# CONSUME SEMANTICS (the T** contract): join and a successful detach both
# NULL the C-side handle slot, so any later use is a deterministic -EINVAL.
# The wrapper mirrors that into NativeThread: after a consuming operation
# `consumed` is set and `handle` reads as null, and further join/detach
# calls raise the decoded errno WITHOUT re-entering C. NativeThread is
# deliberately NOT copyable — two live copies would alias one C handle and
# could each drive it through join independently.
#
# DOCUMENTED b2 ADAPTATIONS (vs spec §11.1 spelling):
#   - def-only members; no `fn`.
#   - The spec's `NativeThread.spawn(...)` @staticmethod ships as the
#     MODULE-LEVEL factory spawn_native_thread() below. Rationale: an
#     entry point must be a C function pointer, and b2 cannot convert a
#     Mojo function VALUE to a pointer (nominal function types; S0
#     SPIKE_REPORT). Callers produce a CThreadEntry from their own
#     @export("name") abi("C") def via the entry_pointer adrp/add idiom
#     proven in tests/s1/abi/callbacks/conformance_test.mojo — keeping
#     that recipe at module scope (not buried in a static method) keeps
#     the export-symbol ↔ spawn-site pairing legible.
#   - native_thread_id() replaces the spec's NativeThread.current_id()
#     staticmethod for the same reason; NativeThreadId is a comptime alias
#     of UInt64 (SYS-7: the numeric value itself is non-portable —
#     pthread_self cast — and equality is meaningful among LIVE threads
#     only, never across join boundaries).
#   - ThreadOptions.name uses "" for "unnamed" (NULL across FFI). b2's
#     Optional[T] is a tagged wrapper with heap indirection for String;
#     the empty-string sentinel keeps the option POD and the FFI boundary
#     allocation-free apart from one bounded NUL-terminated copy.
#
# PRIORITY DIVERGENCE (SYS-7): ThreadOptions.priority_hint is a RAW,
# platform-defined scheduling value. Per SYS-7 it MUST NOT be presented
# as identical across platforms. It is currently INERT: the frozen
# s2-thread ABI exposes no priority surface (the header is extend-only),
# so the hint is accepted and deliberately NOT forwarded; wiring it is a
# C-layer extension away. Spec §11.2's affinity option has no C surface
# either and is deferred entirely.
#
# ENTRY-POINT RECIPE (how to build the `entry` argument):
#     @export("my_entry")
#     def my_entry(ud: UnsafePointer[Int64, MutAnyOrigin]) abi("C") -> Int64:
#         ud[0] += 1
#         return 0
#     # materialize the code address (adrp/add; Mach-O "_" prefix handled):
#     var addr = inlined_assembly[
#         "adrp ${0:x}, _my_entry@PAGE\n"
#         "add ${0:x}, ${0:x}, _my_entry@PAGEOFF\n",
#         UInt, constraints="=r",
#     ]()
#     var entry = UnsafePointer[NoneType, MutAnyOrigin](
#         unsafe_from_address=Int(addr)
#     )
#
# b2 conventions (matching mojito_sys/time/monotonic.mojo, issue #63):
#   - @extern + abi("C") + `...`; dylib chosen at link time (-Xlinker).
#   - Out-slots are UnsafePointer[..., MutAnyOrigin]: the pointer escapes
#     into an opaque callee, and MutAnyOrigin pins the post-call slot load
#     AFTER the call.
#   - Raw mjs_* externs are importable but NOT for caller use; prefer
#     spawn_native_thread() / join() / detach() / native_thread_id().
#   - Raising goes through the straight-line raise_errno helper
#     (mojito_sys.abi.errors); this module adds no raise sites of its own.

from mojito_sys.abi.errors import raise_errno
from std.memory import stack_allocation

# b2 WORKAROUND (#49): the raw mjs_thread_* bindings live in a pure-extern
# LEAF module (mojito_sys/thread/externs.mojo) that imports nothing and
# hosts no Movable types; every extern invocation happens there through
# non-raising same-module probe_* shims. Two lowering traps were isolated
# under lldb + minimized repros (/tmp/b2repro):
#   1. declaring the externs inside THIS module (which hosts Movable
#      structs and raising machinery) misbinds the spawn call's register
#      arguments — the callee received `userdata` in BOTH the entry and
#      userdata slots;
#   2. letting ANY aggregate (ThreadOptions) flow by value into the frame
#      that reaches the extern makes b2 either SIGSEGV while lowering or
#      collapse the entry/userdata registers onto the options copy.
# spawn_native_thread()/thread_spawn_args() below implement the proven
# shape: options are unpacked OUTSIDE the extern-reaching frame, which
# takes flat scalars and raw pointers only.
import mojito_sys.thread.externs as _externs

comptime ThreadHandle = Int64

# Re-exposed leaf aliases: same names this module always documented, bound
# to the pure-extern leaf's definitions (see the WORKAROUND note above).
comptime HandleSlot = _externs.HandleSlot
comptime CThreadEntry = _externs.CThreadEntry
comptime UserdataPtr = _externs.UserdataPtr
comptime NamePtr = _externs.NamePtr
comptime StatusSlot = _externs.StatusSlot

# Deterministic consumed-handle misuse code (frozen ABI: -errno).
comptime EINVAL_RC = Int32(-22)

# darwin ENAMETOOLONG: enforced wrapper-side at the 15-chars+NUL portable
# floor (see _name_cell) — same observable contract as the C layer.
comptime ENAMETOOLONG_RC = Int32(-63)

# Spec §11's NativeThreadId: raw OS-thread identity (non-portable value,
# SYS-7; live-thread-scoped equality per the frozen header).
comptime NativeThreadId = UInt64



# Null-pointer construction centralization: `unsafe_from_address=0` as a
# literal is rejected in 1.0.0b2, so the zero travels through a runtime
# local (same pattern as mojito_sys/abi/callbacks.mojo).
def _null_handle() -> ThreadHandle:
    return 0


def _null_name() -> NamePtr:
    var zero = 0
    return NamePtr(unsafe_from_address=zero)


# Copy `name` into a NUL-terminated stack cell for the const char* FFI
# boundary. The 15-chars+NUL portable floor (SYS-7, frozen header) is
# enforced HERE with the same -ENAMETOOLONG the C layer returns: b2's
# stack_allocation takes a comptime size, so the buffer is fixed at 16
# bytes and longer names are rejected before the FFI boundary (identical
# observable contract, decided one layer earlier). Freed by stack teardown
# when the spawning frame exits (neither spawn nor set_name retains it).
def _name_cell(name: String) raises -> NamePtr:
    var n = name.byte_length()
    if n > 15:
        raise_errno(ENAMETOOLONG_RC)
    var buf = stack_allocation[16, Byte]()
    var src = name.unsafe_ptr()
    var i = 0
    while i < n:
        buf[i] = src[i]
        i += 1
    buf[n] = 0
    return buf


struct ThreadOptions:
    """Per-spawn options (spec §11.2).

    Blocking: n/a (pure data).
    Allocation: none — `name` is captured into a fixed 16-byte inline
      buffer (the portable floor: 15 chars + NUL, SYS-7) at construction;
      no heap traffic anywhere in this struct.
    Task-aware: no.

    name          : "" means unnamed (NULL across FFI); at most 15 chars +
                    NUL is the portable floor (SYS-7) — longer names make
                    spawn raise -ENAMETOOLONG.
    stack_size    : 0 selects the system default; otherwise >=
                    PTHREAD_STACK_MIN or spawn raises -EINVAL.
    priority_hint : RAW platform scheduling value (SYS-7: MUST NOT be
                    presented as identical across platforms). Currently
                    INERT — accepted but not forwarded (frozen s2-thread
                    ABI has no priority surface; see header docblock).

    b2 WORKAROUND (#49, minimized in /tmp/b2repro): this struct MUST stay
    POD. A String field flowing by-value through the extern-calling spawn
    path makes b2's cross-module lowering either SIGSEGV while lowering or
    bind mjs_thread_spawn's entry/userdata registers to one collapsed
    value. The name therefore travels as fixed bytes + length + a
    too-long flag (checked at spawn time with the same -ENAMETOOLONG the
    C layer would return).
    """

    # Fixed-capacity name storage, packed into two machine words (only
    # [0..name_len) is meaningful and name_len <= MJS_THREAD_NAME_MAX
    # (15) — 16 bytes fit exactly). Excess input sets name_too_long
    # instead of truncating silently.
    var name_lo: UInt64  # bytes [0..8)
    var name_hi: UInt64  # bytes [8..16)
    var name_len: Int
    var name_too_long: Bool
    var stack_size: Int
    var priority_hint: Int

    def __init__(
        out self,
        name: String = "",
        stack_size: Int = 0,
        priority_hint: Int = 0,
    ):
        self.name_lo = 0
        self.name_hi = 0
        var n = name.byte_length()
        self.name_len = n if n <= 15 else 15
        self.name_too_long = n > 15
        var src = name.unsafe_ptr()
        var i = 0
        while i < self.name_len:
            if i < 8:
                self.name_lo |= UInt64(src[i]) << UInt64(i * 8)
            else:
                self.name_hi |= UInt64(src[i]) << UInt64((i - 8) * 8)
            i += 1
        self.stack_size = stack_size
        self.priority_hint = priority_hint


struct NativeThread(Movable):
    """A joinable OS thread handle (spec §11.1), bound to the opaque
    mjs_thread* C handle (SYS-3).

    Consume semantics: join() and detach() each consume the handle exactly
    once — mirroring the C T** contract where both NULL *t on success. Any
    later join()/detach() raises decoded -EINVAL without re-entering C.
    The fields are public by design so conformance tests can pin the
    NULLing behavior; callers should treat them as read-only.

    Blocking: n/a (handle state only; see per-method notes).
    Allocation: none beyond what spawn already paid.
    Task-aware: no — this is a raw OS thread outside the mojito scheduler.
    """

    var handle: ThreadHandle
    var consumed: Bool

    def __init__(out self):
        # Zero/consumed state; real handles arrive only through
        # spawn_native_thread() -> _adopt().
        self.handle = _null_handle()
        self.consumed = True

    # Movable but NOT copyable: a move transfers the single consume
    # ticket, a copy would alias one C handle across two owners.
    def __moveinit__(mut self, mut existing: Self):
        self.handle = existing.handle
        self.consumed = existing.consumed

    @staticmethod
    def _adopt(handle: ThreadHandle) -> NativeThread:
        var t = NativeThread()
        t.handle = handle
        t.consumed = False
        return t^

    # Join the thread: returns the entry function's status value.
    #
    # Blocking: YES (SYS-5) — blocks the calling OS thread until the target
    #   exits (pthread_join underneath); the ONLY blocking primitive of
    #   this module.
    # Allocation: two scratch words (handle slot + status slot), stack-
    #   carved, no heap traffic (SYS-4).
    # Task-aware: no — blocking happens at OS-thread granularity; a mojito
    #   task calling this parks its whole OS thread.
    def join(mut self) raises -> Int64:
        if self.consumed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, ThreadHandle]()
        slot[0] = self.handle
        var status = stack_allocation[1, Int64]()
        var rc = _externs.probe_join(slot, status)
        if rc != 0:
            raise_errno(rc)
        # C consumed the handle (*slot was NULLed — T** contract); mirror
        # that so a second join raises deterministically here.
        self.handle = slot[0]
        self.consumed = True
        return status[]

    # Detach the thread: it reclaims its own resources at exit.
    #
    # Blocking: no (SYS-5) — pthread_detach semantics; returns immediately
    #   regardless of whether the child has already exited (both orders are
    #   deterministic success paths in the C layer).
    # Allocation: one scratch word (handle slot), stack-carved (SYS-4).
    # Task-aware: no.
    def detach(mut self) raises:
        if self.consumed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, ThreadHandle]()
        slot[0] = self.handle
        var rc = _externs.probe_detach(slot)
        if rc != 0:
            raise_errno(rc)
        self.handle = slot[0]  # NULLed by C on success
        self.consumed = True


# Spawn a native OS thread running entry(userdata) with an explicit stack
# size and a NUL-terminated name cell (spec §11.1's NativeThread.spawn,
# shipped module-level per the b2 adaptations documented in the header).
#
# b2 WORKAROUND (#49, minimized under /tmp/b2repro): ONLY scalars and raw
# pointers may flow through a frame that reaches the mjs_thread_spawn
# extern. A ThreadOptions value read inside such a frame (directly or via
# any inlined callee) makes b2's cross-module lowering either SIGSEGV while
# lowering or bind entry/userdata registers to one collapsed value. The
# options-bearing convenience below therefore unpacks BEFORE the extern-
# reaching frame, and this core takes flat scalars only.
#
# Raises (decoded errno) on: NULL entry (-EINVAL), undersized stack_size
# (-EINVAL), or resource exhaustion (-EAGAIN/-ENOMEM).
#
# Blocking: no (SYS-5) — pthread_create returns once the child exists; the
#   name is applied inside the child's trampoline.
# Allocation: one scratch handle word (stack-carved, SYS-4).
# Task-aware: no — deliberately raw OS thread (worker/blocking-pool
#   infrastructure per spec §14; NOT a mojito task).
def spawn_native_thread(
    entry: CThreadEntry,
    userdata: UserdataPtr,
    stack_size: Int,
    name_cell: NamePtr,
) raises -> NativeThread:
    var slot = stack_allocation[1, ThreadHandle]()
    var rc = _externs.probe_spawn(
        entry, userdata, stack_size, name_cell, slot,
    )
    if rc != 0:
        raise_errno(rc)
    return NativeThread._adopt(slot[0])


# Unpack ThreadOptions into the scalar pair spawn_native_thread() consumes
# (stack size + NUL-terminated name cell). Deliberately SEPARATE from the
# spawn path: this frame reads the options struct and must never reach an
# extern (see the WORKAROUND note above). Raises -ENAMETOOLONG when the
# captured name exceeds the 15-chars+NUL portable floor.
#
# Blocking: no (SYS-5). Allocation: one 16-byte scratch cell when named
# (stack-carved, freed at spawning-frame teardown; SYS-4). Task-aware: no.
def thread_spawn_args(options: ThreadOptions) raises -> Tuple[Int, NamePtr]:
    if options.name_too_long:
        raise_errno(ENAMETOOLONG_RC)
    if options.name_len == 0:
        return Tuple(options.stack_size, _null_name())
    var buf = stack_allocation[16, Byte]()
    var i = 0
    while i < options.name_len:
        var w = options.name_lo if i < 8 else options.name_hi
        buf[i] = Byte((w >> ((i % 8) * 8)) & 0xFF)
        i += 1
    buf[options.name_len] = 0
    return Tuple(options.stack_size, NamePtr(buf))


# The NULL name cell: "unnamed" across the FFI boundary (b2 rejects
# `unsafe_from_address=0` literals, so the zero travels through a runtime
# local). Public because spawn_native_thread() takes the name cell
# explicitly per the WORKAROUND-documented scalar spawn surface.
def no_name() -> NamePtr:
    return _null_name()

# Identity of the CALLING thread (spec §11's current_id, shipped
# module-level per the b2 adaptation documented in the header).
#
# Blocking: no (SYS-5) — single register read (pthread_self cast).
# Allocation: none (SYS-4).
# Task-aware: no — OS-thread identity, NEVER a mojito task id; the numeric
#   value is non-portable (SYS-7) and equality is meaningful among LIVE
#   threads only (POSIX may reuse pthread_t values after join).
def native_thread_id() -> UInt64:
    return _externs.probe_self_id()


# Rename the CALLING thread.
#
# Raises (decoded errno) on: empty name (NULL across FFI is rejected by the
# frozen ABI with -EINVAL) and names over the 15-chars+NUL portable floor
# (-ENAMETOOLONG, SYS-7 divergence kept visible).
#
# Blocking: no (SYS-5) — named-register write underneath.
# Allocation: one NUL-terminated copy of `name`, stack-carved (SYS-4).
# Task-aware: no — renames the OS thread, not any mojito task.
def set_current_thread_name(name: String) raises:
    _apply_thread_name(_name_cell_or_raise(name))


def _name_cell_or_raise(name: String) raises -> NamePtr:
    if name.byte_length() == 0:
        raise_errno(EINVAL_RC)
    return _name_cell(name)


def _apply_thread_name(cell: NamePtr) raises:
    var rc = _externs.probe_set_name(cell)
    if rc != 0:
        raise_errno(rc)
