# mojito-sys S3.5 — NativeEvent (issue #61, spec §17).
#
# Spec §17 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s3-event block):
#   mjs_event_init(out)                      — mint an owned handle;
#   mjs_event_wait(e)                        — BLOCKS until a token;
#   mjs_event_wait_until(e, deadline_ns)     — 0 / -ETIMEDOUT / -errno;
#   mjs_event_signal(e)                      — store/wake one token;
#   mjs_event_destroy(&e)                    — CONSUMES the handle.
#
# WAKE SEMANTICS — NORMATIVE CHOICE (spec §17 deliberately leaves the
# breadth and the consumed-vs-sticky question open; this wrapper and
# its C layer pin it, and tests/s3/sync/event asserts exactly this):
#
#   NativeEvent is an AUTO-RESET, BREADTH-ONE event. At most ONE token
#   is pending at any time.
#     - signal() stores one token (if none is pending) and wakes AT
#       MOST ONE parked waiter.
#     - With nobody waiting, the token STICKS: exactly ONE later wait
#       completes without blocking (pre-signal immediate .ok).
#     - Signals issued while a token is already pending COALESCE:
#       five signals with no waiter release exactly one future wait.
#     - A successful wait/wait_until CONSUMES the token; every other
#       waiter keeps sleeping until the next signal.
#     - Fairness is NOT promised: a fresh arrival may consume the
#       token ahead of an already-woken waiter that has not yet
#       reacquired the internal mutex.
#
#   Rationale: §17 asks for "one efficient primitive suitable for
#   waking parked OS worker threads" — each signal releases exactly
#   one worker, which is the semaphore(0,1)/auto-reset shape a
#   blocking-pool park/wake needs. A sticky/manual-reset broadcast
#   would require wake-all breadth and re-check loops at every user.
#
# CLOCK DOMAIN: wait_until takes a MonotonicInstant and forwards its
# raw ticks (nanoseconds in the mjs_clock_now domain) to the C layer.
# The event composes mjs_condvar internally, so ALL platform clock
# handling stays in mjs_condvar.c (Linux condattr CLOCK_MONOTONIC 1:1,
# macOS relative-NP remainder). No wall-clock time participates.
#
# WAIT STATUS MAPPING: 0 -> WaitStatus.ok (token consumed),
# -ETIMEDOUT -> WaitStatus.timed_out (a STATUS like try_lock's -EBUSY),
# any other negative -> raise_errno decode. There are NO spurious
# wakeups through this surface that matter to callers: .ok means a
# token was consumed under the internal lock (the predicate loop lives
# INSIDE the C layer), which is the §17 efficiency win over §16.
#
# CONSUME SEMANTICS: destroy() NULLs the C-side handle slot; any later
# use is a deterministic -EINVAL. The wrapper mirrors that: after a
# successful destroy() `destroyed` is set, `handle` reads as 0, and
# every further method raises the decoded errno WITHOUT re-entering C.
# A default-constructed NativeEvent starts inert; live handles arrive
# only through create() -> _adopt().
#
# b2 conventions + crash workarounds (verbatim from condvar.mojo,
# issues #58/#61 lanes):
#   - @extern bindings + probe shims live in the pure-extern leaf
#     mojito_sys/sync/externs.mojo; this module decodes/raises only
#     AFTER each call has returned.
#   - def-only members; create() factory instead of a raising
#     __init__; out-slots UnsafePointer[..., MutAnyOrigin].
#   - AGGREGATE-RETURNING METHOD + RAISE SITES: wait_until keeps
#     exactly ONE return, ONE raise site, and a single-exit scalar tag
#     merge; the consumed-handle check is delegated to the C layer
#     (-EINVAL surfaces through the generic decode).
#   - CALL IN THE RAISE CONDITION IS POISON: the platform ETIMEDOUT
#     constant is hoisted into a LOCAL before any probe call.
#   - Wrapper methods are callable only from main() scope of the
#     consuming unit; @export test frames drive the scalar probe shims.

from std.memory import stack_allocation
from std.sys import CompilationTarget

import mojito_sys.sync.externs as _externs
from mojito_sys.sync.common import WaitStatus
from mojito_sys.abi.errors import raise_errno
from mojito_sys.time.monotonic import MonotonicInstant

comptime EventHandle = Int64

# Deterministic consumed-handle misuse code (frozen ABI: -errno).
comptime EINVAL_RC = Int32(-22)

# Host-selected timeout status: the C layer returns -ETIMEDOUT compiled
# against the host libc numbering (darwin 60 / Linux 110).
def _etimedout_rc() -> Int32:
    if CompilationTarget().is_macos():
        return Int32(-60)
    return Int32(-110)


def _null_handle() -> EventHandle:
    return 0


struct NativeEvent(Movable):
    """A native OS-thread-blocking auto-reset event (spec §17), bound
    to the opaque mjs_event* C handle (SYS-3).

    WAKE SEMANTICS (normative): AUTO-RESET, BREADTH-ONE — see the
    module head. signal() makes exactly ONE wait complete: a currently
    blocked waiter, or (if none waits) the NEXT single wait. Extra
    signals while a token is pending coalesce. Each successful wait
    consumes the token.

    Consume semantics: destroy() consumes the handle exactly once,
    mirroring the C mjs_event** contract where *e is NULLed on success.
    Any later method call raises decoded -EINVAL without re-entering C.
    The fields are public by design so conformance tests can pin the
    NULLing behavior; callers should treat them as read-only.

    Blocking: yes in the waits (SYS-5) — parks the calling OS thread
      until a token is available or the deadline expires; never yields
      to the mojito scheduler. signal wakes but never waits.
    Allocation: none after initialization (SYS-4; init pays one
      fixed-size handle composed of mutex+condvar+token).
    Task-aware: no — OS-thread granularity per spec §14; NOT for
      application task synchronization.
    """

    var handle: EventHandle
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
    def _adopt(handle: EventHandle) -> NativeEvent:
        var e = NativeEvent()
        e.handle = handle
        e.destroyed = False
        return e^

    # Mint a new native event in the no-token state.
    #
    # Raises (decoded errno): -EFAULT for a NULL out-slot (cannot
    # happen through this path), -ENOMEM on allocation failure.
    #
    # Blocking: no (SYS-5) beyond allocator/pthread init internals.
    # Allocation: ONE fixed-size handle at initialization; none
    #   afterwards for the lifetime of the event (SYS-4).
    # Task-aware: no.
    @staticmethod
    def create() raises -> NativeEvent:
        var slot = stack_allocation[1, EventHandle]()
        var rc = _externs.probe_ev_init(slot)
        if rc != 0:
            raise_errno(rc)
        return NativeEvent._adopt(slot[0])

    # Block until a token is available, then consume it. A pre-stored
    # token completes immediately; there is no predicate to re-check —
    # the auto-reset contract guarantees this wait consumes exactly
    # one signal's worth of wake capacity.
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
        var rc = _externs.probe_ev_wait(h)
        if rc != 0:
            raise_errno(rc)

    # As wait(), bounded by an ABSOLUTE monotonic deadline. Returns
    # WaitStatus.ok once a token was consumed, WaitStatus.timed_out
    # once `deadline` passes first. A past deadline returns .timed_out
    # without blocking unless a token is already pending (.ok then).
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
        var rc = _externs.probe_ev_wait_until(h, deadline.ticks)
        if rc != 0 and rc != et:
            raise_errno(rc)
        var tag = Int32(1)
        if rc == 0:
            tag = Int32(0)
        return WaitStatus(tag)

    # Store one token (if none pending) and wake AT MOST ONE waiter.
    # With nobody waiting the token sticks for the next single wait;
    # further signals coalesce while a token is pending.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle.
    #
    # Blocking: no (SYS-5) — wakes a waiter but never waits itself.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def signal(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_ev_signal(h)
        if rc != 0:
            raise_errno(rc)

    # Destroy the event and consume the handle (C NULLs *e on success;
    # mirrored here). Any later use of `self` raises decoded -EINVAL
    # deterministically, including a second destroy().
    #
    # Precondition: no thread may still be waiting (undefined to
    # destroy a waited-on event; not validated). Join waiters first.
    #
    # Blocking: no (SYS-5) — destroys of the composed primitives do
    #   not block for these handles.
    # Allocation: none (frees the one init-time handle; SYS-4 net zero).
    # Task-aware: no.
    def destroy(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, EventHandle]()
        slot[0] = self.handle
        var rc = _externs.probe_ev_destroy(slot)
        if rc != 0:
            raise_errno(rc)
        # C consumed the handle (*slot was NULLed); mirror that so any
        # later method raises deterministically here.
        self.handle = slot[0]
        self.destroyed = True
