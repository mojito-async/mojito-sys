# mojito-sys S3.1 — NativeMutex (issue #57, spec §15).
#
# Spec §15 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s3-mutex block):
#   mjs_mutex_init(out)      — mint an owned handle;
#   mjs_mutex_lock(m)        — BLOCKS under contention;
#   mjs_mutex_try_lock(m)    — 0 acquired / -EBUSY busy (a STATUS);
#   mjs_mutex_unlock(m)      — release;
#   mjs_mutex_destroy(&m)    — CONSUMES the handle (*m NULLed on success).
#
# CONSUME SEMANTICS: destroy() NULLs the C-side handle slot, so any later
# use is a deterministic -EINVAL. The wrapper mirrors that: after a
# successful destroy() `destroyed` is set, `handle` reads as 0, and every
# further method raises the decoded errno WITHOUT re-entering C. A
# default-constructed NativeMutex starts in that inert state; live
# handles arrive only through create() -> _adopt().
#
# DOCUMENTED b2 ADAPTATIONS (vs spec §15 spelling):
#   - def-only members; no `fn`.
#   - Construction ships as the @staticmethod NativeMutex.create()
#     factory rather than a raising __init__ — mirrors the s2 thread
#     lane's spawn_native_thread() pattern where the extern-reaching
#     path must stay non-raising until the rc is decoded.
#   - try_lock maps the C layer's documented -EBUSY STATUS to False and
#     raises only on genuine errors (-EINVAL on a consumed handle, or an
#     unexpected negative rc) — spec's `try_lock(mut self) -> Bool`.
#
# NativeMutex is deliberately NOT copyable — two live copies would alias
# one C handle and could each drive it through unlock/destroy
# independently.
#
# b2 conventions (matching mojito_sys/thread/thread.mojo, issue #49):
#   - @extern bindings + probe shims live in the pure-extern leaf
#     mojito_sys/sync/externs.mojo (register-misbind workaround); this
#     module decodes/raises only AFTER each call has returned.
#   - Out-slots are UnsafePointer[..., MutAnyOrigin]: the pointer escapes
#     into an opaque callee, and MutAnyOrigin pins the post-call slot
#     load AFTER the call.

comptime MutexHandle = Int64
from mojito_sys.abi.errors import raise_errno
import mojito_sys.sync.externs as _externs

from std.memory import stack_allocation

# Deterministic consumed-handle misuse code (frozen ABI: -errno). darwin
# AND Linux spell EINVAL 22, so this constant is host-portable.
comptime EINVAL_RC = Int32(-22)

# The try_lock busy STATUS from the C layer. darwin AND Linux spell
# EBUSY 16 — host-portable by both numberings.
comptime EBUSY_RC = Int32(-16)


# Null-handle centralization: `unsafe_from_address=0` as a literal is
# rejected in 1.0.0b2, so the zero travels through a runtime local (same
# pattern as mojito_sys/thread/thread.mojo).
def _null_handle() -> MutexHandle:
    return 0


struct NativeMutex(Movable):
    """A native OS-thread-blocking mutex (spec §15), bound to the opaque
    mjs_mutex* C handle (SYS-3).

    Consume semantics: destroy() consumes the handle exactly once,
    mirroring the C mjs_mutex** contract where *m is NULLed on success.
    Any later method call raises decoded -EINVAL without re-entering C.
    The fields are public by design so conformance tests can pin the
    NULLing behavior; callers should treat them as read-only.

    Blocking: yes under contention — see per-method SYS-5 notes.
    Allocation: none after initialization (SYS-4; init pays one
      fixed-size handle).
    Task-aware: no — OS-thread granularity per spec §14; a blocked task
      parks its whole OS thread. NOT for application task synchronization.
    """

    var handle: MutexHandle
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
    def _adopt(handle: MutexHandle) -> NativeMutex:
        var m = NativeMutex()
        m.handle = handle
        m.destroyed = False
        return m^

    # Mint a new unlocked native mutex.
    #
    # Raises (decoded errno): -EFAULT for a NULL out-slot (cannot happen
    # through this path), -ENOMEM on allocation failure.
    #
    # Blocking: no (SYS-5) beyond allocator/pthread_mutex_init internals
    #   — may briefly wait on internal registry/kernel mutexes only in
    #  sofar as malloc and pthread_mutex_init do; never on user contention.
    # Allocation: ONE fixed-size handle at initialization (the C-side
    #   malloc); none afterwards for the lifetime of the mutex (SYS-4).
    # Task-aware: no.
    @staticmethod
    def create() raises -> NativeMutex:
        var slot = stack_allocation[1, MutexHandle]()
        var rc = _externs.probe_init(slot)
        if rc != 0:
            raise_errno(rc)
        return NativeMutex._adopt(slot[0])

    # Lock the mutex; blocks the calling OS thread while it is held
    # elsewhere (spec §15 "Blocking: yes, under contention").
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc from the C layer.
    #
    # Blocking: YES (SYS-5) — futex/ulock wait inside pthread_mutex_lock
    #   under contention; the defining primitive of §14.
    # Allocation: none (SYS-4) after initialization.
    # Task-aware: no — parks the calling OS thread; never yields to the
    #   mojito scheduler.
    def lock(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_lock(h)
        if rc != 0:
            raise_errno(rc)

    # Try to lock WITHOUT blocking: True if acquired, False when the
    # mutex is currently locked (the C layer's documented -EBUSY status).
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc. ONLY genuine contention maps to False.
    #
    # Blocking: no (SYS-5) — single trylock attempt, returns immediately
    #   in either outcome.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def try_lock(mut self) raises -> Bool:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_try_lock(h)
        if rc == 0:
            return True
        if rc == EBUSY_RC:
            return False
        raise_errno(rc)
        # Unreachable: raise_errno always raises; b2 still demands a
        # return on every path of a result-bearing def.
        return False

    # Unlock the mutex previously locked by the calling thread.
    #
    # Raises (decoded errno): -EINVAL on a consumed/NULL handle; any
    # unexpected negative rc from the C layer. Unlocking a mutex the
    # caller does not own is POSIX-undefined and NOT validated here.
    #
    # Blocking: no (SYS-5) — may wake a waiter but never waits itself.
    # Allocation: none (SYS-4).
    # Task-aware: no.
    def unlock(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var h = self.handle
        var rc = _externs.probe_unlock(h)
        if rc != 0:
            raise_errno(rc)

    # Destroy the mutex and consume the handle (C NULLs *m on success;
    # mirrored here). Any later use of `self` raises decoded -EINVAL
    # deterministically, including a second destroy().
    #
    # Precondition: the caller must NOT hold the lock (POSIX-undefined to
    # destroy a locked mutex; not validated).
    #
    # Blocking: no (SYS-5) — pthread_mutex_destroy with default
    #   attributes never blocks on this platform pair.
    # Allocation: none (frees the one init-time handle; SYS-4 net zero).
    # Task-aware: no.
    def destroy(mut self) raises:
        if self.destroyed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, MutexHandle]()
        slot[0] = self.handle
        var rc = _externs.probe_destroy(slot)
        if rc != 0:
            raise_errno(rc)
        # C consumed the handle (*slot was NULLed); mirror that so any
        # later method raises deterministically here.
        self.handle = slot[0]
        self.destroyed = True
