# mojito-sys S3.2 — NativeCondVar (issue #58, spec §16).
#
# Spec §16 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s3-condvar block):
#   mjs_condvar_init(out)                    — mint an owned handle;
#   mjs_condvar_wait(c, m)                   — BLOCKS until woken;
#   mjs_condvar_wait_until(c, m, deadline_ns)— 0 / -ETIMEDOUT / -errno;
#   mjs_condvar_signal(c)                    — wake at most one;
#   mjs_condvar_broadcast(c)                 — wake all;
#   mjs_condvar_destroy(&c)                  — CONSUMES the handle.
#
# CLOCK DOMAIN (the issue #58 trap): wait_until takes a MonotonicInstant
# and forwards its raw ticks — nanoseconds in the mjs_clock_now domain —
# to the C layer, which maps them onto the platform's pthread_cond clock:
# Linux via pthread_condattr_setclock(CLOCK_MONOTONIC) at init (1:1
# abstime conversion), macOS via the documented relative-NP fallback
# (remainder = deadline - mjs_clock_now(), recomputed per call; macOS has
# no pthread_condattr_setclock). No wall-clock time participates anywhere
# on either side of the boundary.
#
# WAIT STATUS MAPPING: 0 -> WaitStatus.ok, -ETIMEDOUT ->
# WaitStatus.timed_out (a STATUS like NativeMutex.try_lock's -EBUSY),
# any other negative -> raise_errno decode. SPURIOUS WAKEUPS ARE
# PERMITTED BY CONTRACT (mojito_sys.sync.common): .ok NEVER proves a
# predicate true — every caller MUST re-check under the mutex and loop.
# The untimed wait() maps any nonzero rc to a decoded raise (pthread
# cond wait has no other documented status).
#
# ETIMEDOUT IS PLATFORM-SPLIT: darwin spells it 60, Linux 110 (unlike
# EINVAL/EBUSY which coincide). The constant is host-selected through
# CompilationTarget, matching mojito_sys.abi.errors' host-selected errno
# tables.
#
# CONSUME SEMANTICS: destroy() NULLs the C-side handle slot, so any
# later use is a deterministic -EINVAL. The wrapper mirrors that: after
# a successful destroy() `destroyed` is set, `handle` reads as 0, and
# every further method raises the decoded errno WITHOUT re-entering C.
# A default-constructed NativeCondVar starts in that inert state; live
# handles arrive only through create() -> _adopt().
#
# DOCUMENTED b2 ADAPTATIONS (vs spec §16 spelling):
#   - def-only members; no `fn`.
#   - Construction ships as the @staticmethod create() factory rather
#     than a raising __init__ — mirrors NativeMutex.create() / the s2
#     spawn_native_thread() pattern where the extern-reaching path stays
#     non-raising until the rc is decoded.
#   - The mutex parameter travels as a plain borrowed value (`mutex:
#     NativeMutex`, the only non-copying spelling this toolchain
#     accepts here): NativeMutex is deliberately not copyable, so the
#     borrow preserves the caller's handle. Spec §16's `ref` spelling
#     is not accepted by b2 (compile probe, issue #58 lane).
#
# DOCUMENTED b2 CRASH WORKAROUNDS (issue #58 lane; both hit live while
# landing this wrapper — recorded here beside the #49 leaf-module
# doctrine because they extend it):
#   1. AGGREGATE-RETURNING METHOD + RAISE SITES: b2 1.0.0b2 SIGSEGVs in
#      the pass manager when wait_until carried (a) more than one return
#      statement alongside any raise site, or (b) a second raise site
#      (the consumed-handle EINVAL pre-check) ahead of its decode.
#      Scalar-returning shapes always lower fine (cf. try_lock's Bool).
#      wait_until below therefore keeps exactly ONE return, ONE raise
#      site, and a single-exit scalar tag merge. The consumed-handle
#      check is delegated to the C layer: mjs_condvar_wait_until returns
#      -EINVAL for a consumed handle and the generic decode surfaces the
#      identical decoded errno (documented deviation from the other
#      methods' no-re-entry promise).
#   2. CALL IN THE RAISE CONDITION IS POISON: branching on a helper CALL
#      (`rc != _etimedout_rc()`) inside this method's condition also
#      SIGSEGVs; the platform constant MUST be hoisted into a LOCAL
#      before the probe call (`var et = _etimedout_rc()`), after which
#      everything lowers cleanly. Additionally, even the fixed shape
#      must only be CALLED directly from main() scope of the consuming
#      unit — intermediate test wrappers / @export frames calling it
#      still crash; those contexts use the scalar probe shims in
#      sync/externs.mojo and decode raw rcs themselves (the conformance
#      suite encodes exactly this split).
#
# b2 conventions (matching mojito_sys/sync/mutex.mojo, issue #57):
#   - @extern bindings + probe shims live in the pure-extern leaf
#     mojito_sys/sync/externs.mojo (register-misbind workaround); this
#     module decodes/raises only AFTER each call has returned.
#   - Out-slots are UnsafePointer[..., MutAnyOrigin]: the pointer escapes
#     into an opaque callee, and MutAnyOrigin pins the post-call slot
#     load AFTER the call.

from std.memory import stack_allocation
from std.sys import CompilationTarget

from mojito_sys.sync.common import WaitStatus
import mojito_sys.sync.externs as _externs
from mojito_sys.sync.mutex import NativeMutex
from mojito_sys.time.monotonic import MonotonicInstant
from mojito_sys.abi.errors import raise_errno

comptime CondHandle = Int64

# Deterministic consumed-handle misuse code (frozen ABI: -errno). darwin
# AND Linux spell EINVAL 22, so this constant is host-portable.
comptime EINVAL_RC = Int32(-22)

# Host-selected timeout status: the C layer returns -ETIMEDOUT compiled
# against the host libc numbering. Blocking: no (SYS-5) — pure comptime
# arithmetic. Allocation: none. Task-aware: no.
def _etimedout_rc() -> Int32:
    if CompilationTarget().is_macos():
        return Int32(-60)  # darwin ETIMEDOUT
    return Int32(-110)  # Linux ETIMEDOUT


# Scalar guard for the consumed-handle pre-check (raises decoded
# -EINVAL). Kept outside wait_until itself: b2 1.0.0b2 crashes when the
# aggregate-returning timed-wait method carries this raise alongside its
# decode logic (see head, crash workaround 1).
def _require_live(destroyed: Bool) raises:
    if destroyed:
        raise_errno(EINVAL_RC)


# Null-handle centralization: `unsafe_from_address=0` as a literal is
# rejected in 1.0.0b2, so the zero travels through a runtime local (same
# pattern as mutex.mojo).
def _null_handle() -> CondHandle:
    return 0


struct NativeCondVar(Movable):
    """A native OS-thread-blocking condition variable (spec §16), bound
    to the opaque mjs_condvar* C handle (SYS-3).

    Consume semantics: destroy() consumes the handle exactly once,
    mirroring the C mjs_condvar** contract where *c is NULLed on success.
    Any later method call raises decoded -EINVAL without re-entering C.
    The fields are public by design so conformance tests can pin the
    NULLing behavior; callers should treat them as read-only.

    Precondition on BOTH waits: the caller holds `mutex`. Every wake —
    INCLUDING WaitStatus.ok — may be spurious (sync/common.mojo
    contract); callers must re-check their predicate in a loop.

    Blocking: yes in the waits (SYS-5) — parks the calling OS thread
      until woken or the deadline expires; never yields to the mojito
      scheduler. signal/broadcast wake but never wait.
    Allocation: none after initialization (SYS-4; init pays one
      fixed-size handle).
    Task-aware: no — OS-thread granularity per spec §14; NOT for
      application task synchronization.
    """

    var handle: CondHandle
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
    def _adopt(handle: CondHandle) -> NativeCondVar:
        var c = NativeCondVar()
        c.handle = handle
        c.destroyed = False
        return c^

    # Mint a new native condvar (Linux pins its internal clock to
    # CLOCK_MONOTONIC via condattr; see the s3-condvar header block).
    #
    # Raises (decoded errno): -EFAULT for a NULL out-slot (cannot happen
    # through this path), -ENOMEM on allocation failure.
    #
    # Blocking: no (SYS-5) beyond allocator/pthread_cond_init internals.
    # Allocation: ONE fixed-size handle at initialization; none
    #   afterwards for the lifetime of the condvar (SYS-4).
    # Task-aware: no.
    @staticmethod
    def create() raises -> NativeCondVar:
        var slot = stack_allocation[1, CondHandle]()
        var rc = _externs.probe_cv_init(slot)
        if rc != 0:
            raise_errno(rc)
        return NativeCondVar._adopt(slot[0])

    # Block until woken, releasing `mutex` atomically on sleep and
    # reacquiring before return (caller must hold it). SPURIOUS WAKES
    # ARE PERMITTED: re-check the predicate and loop.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc from the C layer.
    #
    # Blocking: YES (SYS-5) — parks the calling OS thread until
    #   signal/broadcast arrives.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def wait(mut self, mutex: NativeMutex) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_cv_wait(h, mutex.handle)
        if rc != 0:
            raise_errno(rc)

    # As wait(), bounded by an ABSOLUTE monotonic deadline. Returns
    # WaitStatus.ok once woken (predicate may STILL be false — loop),
    # WaitStatus.timed_out once `deadline` passes; genuine errors raise
    # the decoded errno. A past deadline returns .timed_out without
    # blocking.
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
    def wait_until(
        mut self, mutex: NativeMutex, deadline: MonotonicInstant
    ) raises -> WaitStatus:
        # NOTE: no consumed-handle pre-check here — see crash
        # workaround 1 in the module head. The C layer returns -EINVAL
        # for a consumed handle and the generic decode below surfaces
        # the identical decoded errno.
        var et = _etimedout_rc()
        var h = self.handle
        var rc = _externs.probe_cv_wait_until(h, mutex.handle, deadline.ticks)
        if rc != 0 and rc != et:
            raise_errno(rc)
        var tag = Int32(1)
        if rc == 0:
            tag = Int32(0)
        return WaitStatus(tag)

    # Wake AT MOST ONE thread currently blocked in wait/wait_until on
    # this condvar (a no-op when none wait).
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
        var rc = _externs.probe_cv_signal(h)
        if rc != 0:
            raise_errno(rc)

    # Wake ALL threads currently blocked in wait/wait_until on this
    # condvar.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle.
    #
    # Blocking: no (SYS-5) — wakes waiters but never waits itself.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def broadcast(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_cv_broadcast(h)
        if rc != 0:
            raise_errno(rc)

    # Destroy the condvar and consume the handle (C NULLs *c on success;
    # mirrored here). Any later use of `self` raises decoded -EINVAL
    # deterministically, including a second destroy().
    #
    # Precondition: no thread may still be waiting (POSIX-undefined to
    # destroy a waited-on condvar; not validated). The caller typically
    # joins its waiters first.
    #
    # Blocking: no (SYS-5) — pthread_cond_destroy with default
    #   attributes does not block for these handles.
    # Allocation: none (frees the one init-time handle; SYS-4 net zero).
    # Task-aware: no.
    def destroy(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, CondHandle]()
        slot[0] = self.handle
        var rc = _externs.probe_cv_destroy(slot)
        if rc != 0:
            raise_errno(rc)
        # C consumed the handle (*slot was NULLed); mirror that so any
        # later method raises deterministically here.
        self.handle = slot[0]
        self.destroyed = True
