# mojito-sys S3.7 — NativeSemaphore (issue #106, spec §14/§17).
#
# Spec §17 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s3-sem block):
#   mjs_sem_init(initial, out)         — mint an owned handle;
#   mjs_sem_post(s)                    — release ONE permit;
#   mjs_sem_wait(s)                    — BLOCKS until one permit;
#   mjs_sem_wait_until(s, deadline_ns) — 0 / -ETIMEDOUT / -errno;
#   mjs_sem_try_wait(s)                — 0 / -EBUSY (status) / -errno;
#   mjs_sem_destroy(&s)                — CONSUMES the handle.
#
# PERMIT-ACCOUNTING SEMANTICS (NORMATIVE — spec §14 names permit
# accounting among the sync primitives but leaves breadth open; this
# wrapper and its C layer pin it, and tests/s3/sync/semaphore asserts
# exactly this):
#
#   NativeSemaphore is a COUNTING semaphore holding a NON-NEGATIVE
#   permit count.
#     - post() releases ONE permit: increments the count and wakes AT
#       MOST ONE parked waiter.
#     - With nobody waiting, a post leaves its permit RESIDENT and
#       permits ACCUMULATE: N posts with no waiter leave N permits, so
#       exactly N later waits complete without blocking (a counting
#       semaphore, NOT NativeEvent's coalescing signal — the S3.7
#       distinguishing test).
#     - wait()/wait_until() block while the count is zero, then
#       DECREMENT it. Each permit is consumed by EXACTLY ONE wait;
#       permits are conserved across posts and waits.
#     - try_wait() acquires WITHOUT blocking: True once a permit was
#       taken, False when the count is zero.
#     - The count NEVER goes negative: an acquisition that would take
#       it below zero instead blocks (wait) or returns False (try_wait).
#       Fairness is NOT promised: a fresh arrival may acquire a permit
#       ahead of an already-woken waiter that has not yet reacquired
#       the internal mutex.
#
# CLOCK DOMAIN: wait_until takes a MonotonicInstant and forwards its raw
# ticks (nanoseconds in the mjs_clock_now domain) to the C layer. The
# semaphore composes mjs_condvar internally like NativeEvent, so ALL
# platform clock handling stays in mjs_condvar.c (Linux condattr
# CLOCK_MONOTONIC 1:1, macOS relative-NP remainder). No wall-clock time
# participates.
#
# WAIT STATUS MAPPING: 0 -> WaitStatus.ok (permit consumed),
# -ETIMEDOUT -> WaitStatus.timed_out (a STATUS like try_lock's -EBUSY),
# any other negative -> raise_errno decode. try_wait maps 0 -> True and
# -EBUSY -> False; every other negative -> raise_errno. There are NO
# spurious wakeups through this surface that matter to callers: .ok
# means a permit was consumed under the internal lock (the predicate
# loop lives INSIDE the C layer), which is the §17 efficiency win over
# §16.
#
# CONSUME SEMANTICS: destroy() NULLs the C-side handle slot; any later
# use is a deterministic -EINVAL. The wrapper mirrors that: after a
# successful destroy() `destroyed` is set, `handle` reads as 0, and
# every further method raises the decoded errno WITHOUT re-entering C.
# A default-constructed NativeSemaphore starts inert; live handles
# arrive only through create() -> _adopt().
#
# b2 conventions + crash workarounds (verbatim from condvar.mojo /
# event.mojo, issues #58/#61 lanes):
#   - @extern bindings + probe shims live in the pure-extern leaf
#     mojito_sys/sync/externs.mojo; this module decodes/raises only
#     AFTER each call has returned.
#   - def-only members; create() factory instead of a raising
#     __init__; out-slots UnsafePointer[..., MutAnyOrigin].
#   - AGGREGATE-RETURNING METHOD + RAISE SITES: wait_until keeps
#     exactly ONE return, ONE raise site, and a single-exit scalar tag
#     merge; the consumed-handle check is delegated to the C layer
#     (-EINVAL surfaces through the generic decode).
#   - CALL IN THE RAISE CONDITION IS POISON: the platform ETIMEDOUT/
#     EBUSY constants are hoisted into LOCALS before any probe call.
#   - Wrapper methods are callable only from main() scope of the
#     consuming unit; @export test frames drive the scalar probe shims.

from std.memory import stack_allocation
from std.sys import CompilationTarget

import mojito_sys.sync.externs as _externs
from mojito_sys.sync.common import WaitStatus
from mojito_sys.abi.errors import raise_errno
from mojito_sys.time.monotonic import MonotonicInstant

comptime SemaphoreHandle = Int64

# Deterministic consumed-handle misuse code (frozen ABI: -errno).
comptime EINVAL_RC = Int32(-22)

# try_wait empty-semaphore status: -EBUSY (16 on both darwin and linux;
# frozen ABI returns it verbatim, do not negate here).
comptime EBUSY_RC = Int32(-16)

# Host-selected timeout status: the C layer returns -ETIMEDOUT compiled
# against the host libc numbering (darwin 60 / Linux 110).
def _etimedout_rc() -> Int32:
    if CompilationTarget().is_macos():
        return Int32(-60)
    return Int32(-110)


def _null_handle() -> SemaphoreHandle:
    return 0


struct NativeSemaphore(Movable):
    """A native OS-thread-blocking COUNTING semaphore (spec §14/§17),
    bound to the opaque mjs_sem* C handle (SYS-3).

    PERMIT-ACCOUNTING SEMANTICS (normative): a non-negative permit
    count — see the module head. post() releases one permit (permits
    accumulate), wait()/wait_until() consume exactly one each, and
    try_wait() acquires without blocking. The count never goes
    negative: an acquisition that would take it below zero blocks
    (wait) or returns False (try_wait).

    Consume semantics: destroy() consumes the handle exactly once,
    mirroring the C mjs_sem** contract where *s is NULLed on success.
    Any later method call raises decoded -EINVAL without re-entering C.
    The fields are public by design so conformance tests can pin the
    NULLing behavior; callers should treat them as read-only.

    Blocking: yes in wait/wait_until (SYS-5) — parks the calling OS
      thread until a permit is available or the deadline expires; never
      yields to the mojito scheduler. post wakes but never waits;
      try_wait never blocks.
    Allocation: none after initialization (SYS-4; init pays one
      fixed-size handle composed of mutex+condvar+count).
    Task-aware: no — OS-thread granularity per spec §14; NOT for
      application task synchronization.
    """

    var handle: SemaphoreHandle
    var destroyed: Bool

    def __init__(out self):
        # Inert/consumed state; real handles arrive only through
        # create() -> _adopt().
        self.handle = _null_handle()
        self.destroyed = True

    # Movable but NOT copyable: a move transfers the single consume
    # ticket, a copy would alias one C handle across two owners.
    def __moveinit__(mut self, mut existing: Self):
        self.handle = existing.handle
        self.destroyed = existing.destroyed

    @staticmethod
    def _adopt(handle: SemaphoreHandle) -> NativeSemaphore:
        var s = NativeSemaphore()
        s.handle = handle
        s.destroyed = False
        return s^

    # Mint a new counting semaphore holding `initial` permits (>= 0).
    #
    # Raises (decoded errno): -EINVAL for a negative initial count or
    #   misuse (cannot happen through this path's non-negative literal),
    #   -EFAULT for a NULL out-slot, -ENOMEM on allocation failure.
    #
    # Blocking: no (SYS-5) beyond allocator/pthread init internals.
    # Allocation: ONE fixed-size handle at initialization; none
    #   afterwards for the lifetime of the semaphore (SYS-4).
    # Task-aware: no.
    @staticmethod
    def create(initial: Int) raises -> NativeSemaphore:
        var slot = stack_allocation[1, SemaphoreHandle]()
        var rc = _externs.probe_sem_init(Int32(initial), slot)
        if rc != 0:
            raise_errno(rc)
        return NativeSemaphore._adopt(slot[0])

    # Block until a permit is available, then consume exactly one. A
    # pre-posted permit completes immediately; there is no predicate to
    # re-check — the counting contract guarantees this wait consumes
    # exactly one permit's worth of wake capacity.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc from the C layer.
    #
    # Blocking: YES (SYS-5).
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def wait(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_sem_wait(h)
        if rc != 0:
            raise_errno(rc)

    # As wait(), bounded by an ABSOLUTE monotonic deadline. Returns
    # WaitStatus.ok once a permit was consumed, WaitStatus.timed_out
    # once `deadline` passes first. A past deadline returns .timed_out
    # without blocking unless a permit is already available (.ok then).
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle or an
    # unavailable clock; any unexpected negative rc.
    #
    # Blocking: YES (SYS-5) — bounded variant of wait().
    # Allocation: none (SYS-4).
    # Task-aware: no.
    #
    # NOTE the single-exit lowering in the body (crash workaround 1 in
    # the module head) and the main-scope-only call rule (workaround 2).
    def wait_until(mut self, deadline: MonotonicInstant) raises -> WaitStatus:
        # NOTE: no consumed-handle pre-check here — see crash
        # workaround 1 in the module head. The C layer returns -EINVAL
        # for a consumed handle and the generic decode below surfaces
        # the identical decoded errno.
        var et = _etimedout_rc()
        var h = self.handle
        var rc = _externs.probe_sem_wait_until(h, deadline.ticks)
        if rc != 0 and rc != et:
            raise_errno(rc)
        var tag = Int32(1)
        if rc == 0:
            tag = Int32(0)
        return WaitStatus(tag)

    # Acquire ONE permit WITHOUT blocking. Returns True when a permit
    # was taken, False when the semaphore is empty (the try_lock-style
    # -EBUSY status decoded). Never blocks the calling OS thread.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc.
    #
    # Blocking: no (SYS-5).
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def try_wait(mut self) raises -> Bool:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var eb = EBUSY_RC
        var h = self.handle
        var rc = _externs.probe_sem_try_wait(h)
        if rc == 0:
            return True
        if rc == eb:
            return False
        raise_errno(rc)
        return False

    # Release ONE permit: increments the count and wakes AT MOST ONE
    # parked waiter. With nobody waiting the permit stays resident for
    # the next single wait; permits accumulate (counting semantics).
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle.
    #
    # Blocking: no (SYS-5) — wakes a waiter but never waits itself.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def post(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_sem_post(h)
        if rc != 0:
            raise_errno(rc)

    # Destroy the semaphore and consume the handle (C NULLs *s on
    # success; mirrored here). Any later use of `self` raises decoded
    # -EINVAL deterministically, including a second destroy().
    #
    # Precondition: no thread may still be waiting (undefined to
    # destroy a waited-on semaphore; not validated). Join waiters first.
    #
    # Blocking: no (SYS-5) — destroys of the composed primitives do
    #   not block for these handles.
    # Allocation: none (frees the one init-time handle; SYS-4 net zero).
    # Task-aware: no.
    def destroy(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, SemaphoreHandle]()
        slot[0] = self.handle
        var rc = _externs.probe_sem_destroy(slot)
        if rc != 0:
            raise_errno(rc)
        # C consumed the handle (*slot was NULLed); mirror that so any
        # later method raises deterministically here.
        self.handle = slot[0]
        self.destroyed = True