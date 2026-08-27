# mojito-sys S3.1+S3.2 — raw mjs_mutex_* / mjs_condvar_* FFI bindings
# (issues #57, #58).
# LEAF MODULE (b2 WORKAROUND precedent #49): this file deliberately
# contains ONLY @extern declarations and the comptime pointer aliases
# they need — no imports, no structs, no raise sites. b2 1.0.0b2's
# cross-module lowering misbinds extern call arguments when the
# DECLARING module also hosts Movable structs and/or raising machinery
# (the s2-thread spawn collapse; see mojito_sys/thread/externs.mojo).
# The proven shape is: pure-extern leaf + same-module probe_* shims +
# decode/raise only in the wrapper AFTER the call returns.
#
# NEVER-INLINE INVARIANT: the probe_* shims below are the ONLY sanctioned
# call path into the mjs_mutex_* bindings and MUST stay tiny,
# non-raising, aggregate-free, and free of @always_inline at every call
# site. These symbols are NOT for caller use; prefer NativeMutex
# (mojito_sys.sync.mutex). Out-slots are UnsafePointer[..., MutAnyOrigin]:
# the pointer escapes into an opaque callee, and MutAnyOrigin pins the
# post-call slot load AFTER the call.

# Opaque mjs_mutex* handle (SYS-3): never dereferenced Mojo-side; minted
# by mjs_mutex_init, consumed (NULLed by zero) by mjs_mutex_destroy.
# Carried as a RAW MACHINE WORD (Int64) — same convention as the s2
# thread handle.
comptime MutexHandle = Int64

# mjs_mutex_init / mjs_mutex_destroy take mjs_mutex** slots; declared
# here as Int64 cells (the machine word holding the handle address).
comptime MutexSlot = UnsafePointer[Int64, MutAnyOrigin]

# Single-level mjs_mutex* argument of lock/try_lock/unlock. Int64 pointee
# is a formality — the address is never dereferenced Mojo-side.
comptime MutexPtr = UnsafePointer[Int64, MutAnyOrigin]


@extern("mjs_mutex_init")
def mjs_mutex_init(out_slot: MutexSlot) abi("C") -> Int32:
    ...


@extern("mjs_mutex_lock")
def mjs_mutex_lock(m: MutexPtr) abi("C") -> Int32:
    ...


@extern("mjs_mutex_try_lock")
def mjs_mutex_try_lock(m: MutexPtr) abi("C") -> Int32:
    ...


@extern("mjs_mutex_unlock")
def mjs_mutex_unlock(m: MutexPtr) abi("C") -> Int32:
    ...


@extern("mjs_mutex_destroy")
def mjs_mutex_destroy(slot: MutexSlot) abi("C") -> Int32:
    ...


# ---- non-raising call shims (leaf-module boundary) --------------------------
#
# Every mjs_mutex_* invocation happens HERE, in the pure leaf, and returns
# the raw C rc; mojito_sys.sync.mutex decodes/raises only afterwards.


def probe_init(out_slot: MutexSlot) -> Int32:
    return mjs_mutex_init(out_slot)


def probe_lock(handle: MutexHandle) -> Int32:
    return mjs_mutex_lock(MutexPtr(unsafe_from_address=Int(handle)))


def probe_try_lock(handle: MutexHandle) -> Int32:
    return mjs_mutex_try_lock(MutexPtr(unsafe_from_address=Int(handle)))


def probe_unlock(handle: MutexHandle) -> Int32:
    return mjs_mutex_unlock(MutexPtr(unsafe_from_address=Int(handle)))


def probe_destroy(slot: MutexSlot) -> Int32:
    return mjs_mutex_destroy(slot)


# ---- S3.2: mjs_condvar_* bindings (issue #58) -------------------------------
#
# Same leaf-module discipline as the mjs_mutex_* block above. The
# wait_until deadline is an ABSOLUTE monotonic nanosecond count (the
# mjs_clock_now domain; the C layer maps it onto the platform's
# pthread_cond clock — see the s3-condvar header block). wait_until
# returns 0 / -ETIMEDOUT / -errno; the wrapper decodes the -ETIMEDOUT
# STATUS into WaitStatus.timed_out.
comptime CondHandle = Int64

# mjs_condvar_init / mjs_condvar_destroy take mjs_condvar** slots.
comptime CondSlot = UnsafePointer[Int64, MutAnyOrigin]

# Single-level mjs_condvar* argument of signal/broadcast.
comptime CondPtr = UnsafePointer[Int64, MutAnyOrigin]


@extern("mjs_condvar_init")
def mjs_condvar_init(out_slot: CondSlot) abi("C") -> Int32:
    ...


@extern("mjs_condvar_wait")
def mjs_condvar_wait(c: CondPtr, m: MutexPtr) abi("C") -> Int32:
    ...


@extern("mjs_condvar_wait_until")
def mjs_condvar_wait_until(
    c: CondPtr, m: MutexPtr, deadline_ns: UInt64
) abi("C") -> Int32:
    ...


# ---- S3.3 atomic wait/wake (issue #59, spec §18) ----------------------------
#
# Same leaf-module discipline as the mjs_mutex_* block above: raw @extern
# bindings + non-raising probe_* shims ONLY. The address argument is a
# machine-word-backed pointer (the C layer never stores it past the call);
# deadline_ns is a NULL-able uint64_t* cell (NULL = wait forever), carried
# as UnsafePointer[UInt64, MutAnyOrigin] with the zero address as the
# documented NULL.
comptime WordPtr = UnsafePointer[UInt32, MutAnyOrigin]
comptime DeadlineSlot = UnsafePointer[UInt64, MutAnyOrigin]


@extern("mjs_atomic_wait_on_u32")
def mjs_atomic_wait_on_u32(
    addr: WordPtr, expected: Int32, deadline_ns: DeadlineSlot
) abi("C") -> Int32:
    ...


@extern("mjs_condvar_signal")
def mjs_condvar_signal(c: CondPtr) abi("C") -> Int32:
    ...


@extern("mjs_condvar_broadcast")
def mjs_condvar_broadcast(c: CondPtr) abi("C") -> Int32:
    ...


@extern("mjs_condvar_destroy")
def mjs_condvar_destroy(slot: CondSlot) abi("C") -> Int32:
    ...


def probe_cv_init(out_slot: CondSlot) -> Int32:
    return mjs_condvar_init(out_slot)


def probe_cv_wait(c: CondHandle, m: MutexHandle) -> Int32:
    return mjs_condvar_wait(
        CondPtr(unsafe_from_address=Int(c)),
        MutexPtr(unsafe_from_address=Int(m)),
    )


def probe_cv_wait_until(c: CondHandle, m: MutexHandle, dl: UInt64) -> Int32:
    return mjs_condvar_wait_until(
        CondPtr(unsafe_from_address=Int(c)),
        MutexPtr(unsafe_from_address=Int(m)),
        dl,
    )


def probe_cv_signal(c: CondHandle) -> Int32:
    return mjs_condvar_signal(CondPtr(unsafe_from_address=Int(c)))


def probe_cv_broadcast(c: CondHandle) -> Int32:
    return mjs_condvar_broadcast(CondPtr(unsafe_from_address=Int(c)))


def probe_cv_destroy(slot: CondSlot) -> Int32:
    return mjs_condvar_destroy(slot)


@extern("mjs_atomic_wake_one_u32")
def mjs_atomic_wake_one_u32(addr: WordPtr) abi("C") -> Int32:
    ...


@extern("mjs_atomic_wake_all_u32")
def mjs_atomic_wake_all_u32(addr: WordPtr) abi("C") -> Int32:
    ...


def probe_wait_on(addr: WordPtr, expected: Int32, dl: DeadlineSlot) -> Int32:
    return mjs_atomic_wait_on_u32(addr, expected, dl)


def probe_wake_one(addr: WordPtr) -> Int32:
    return mjs_atomic_wake_one_u32(addr)


def probe_wake_all(addr: WordPtr) -> Int32:
    return mjs_atomic_wake_all_u32(addr)


# ---- S3.5: mjs_event_* bindings (issue #61) ---------------------------------
#
# Same leaf-module discipline as the blocks above. The wait_until
# deadline is an ABSOLUTE monotonic nanosecond count (the mjs_clock_now
# domain); wait_until returns 0 / -ETIMEDOUT / -errno exactly like the
# condvar binding — the wrapper decodes the -ETIMEDOUT STATUS into
# WaitStatus.timed_out. Wake semantics live in the C ABI block
# (auto-reset, breadth-one; see the s3-event header comment).
comptime EventHandle = Int64

# mjs_event_init / mjs_event_destroy take mjs_event** slots.
comptime EventSlot = UnsafePointer[Int64, MutAnyOrigin]

# Single-level mjs_event* argument of wait/wait_until/signal.
comptime EventPtr = UnsafePointer[Int64, MutAnyOrigin]


@extern("mjs_event_init")
def mjs_event_init(out_slot: EventSlot) abi("C") -> Int32:
    ...


@extern("mjs_event_wait")
def mjs_event_wait(e: EventPtr) abi("C") -> Int32:
    ...


@extern("mjs_event_wait_until")
def mjs_event_wait_until(e: EventPtr, deadline_ns: UInt64) abi("C") -> Int32:
    ...


@extern("mjs_event_signal")
def mjs_event_signal(e: EventPtr) abi("C") -> Int32:
    ...


@extern("mjs_event_destroy")
def mjs_event_destroy(slot: EventSlot) abi("C") -> Int32:
    ...


def probe_ev_init(out_slot: EventSlot) -> Int32:
    return mjs_event_init(out_slot)


def probe_ev_wait(e: EventHandle) -> Int32:
    return mjs_event_wait(EventPtr(unsafe_from_address=Int(e)))


def probe_ev_wait_until(e: EventHandle, dl: UInt64) -> Int32:
    return mjs_event_wait_until(EventPtr(unsafe_from_address=Int(e)), dl)


def probe_ev_signal(e: EventHandle) -> Int32:
    return mjs_event_signal(EventPtr(unsafe_from_address=Int(e)))


def probe_ev_destroy(slot: EventSlot) -> Int32:
    return mjs_event_destroy(slot)


# ---- S3.7: mjs_sem_* bindings (issue #106) ----------------------------------
#
# Same leaf-module discipline as the blocks above. mjs_sem_init takes an
# initial permit count (non-negative; < 0 is -EINVAL) plus an out-slot;
# mjs_sem_wait_until takes an ABSOLUTE monotonic nanosecond deadline (the
# mjs_clock_now domain) and returns 0 / -ETIMEDOUT / -errno — the wrapper
# decodes the -ETIMEDOUT STATUS into WaitStatus.timed_out. mjs_sem_try_wait
# returns 0 when a permit was taken, -EBUSY (status) when empty, otherwise
# -errno. Permit-accounting semantics live in the C ABI block (counting
# semaphore, non-negative count; see the s3-sem header comment).
comptime SemHandle = Int64

# mjs_sem_init / mjs_sem_destroy take mjs_sem** slots.
comptime SemSlot = UnsafePointer[Int64, MutAnyOrigin]

# Single-level mjs_sem* argument of wait/wait_until/try_wait/post.
comptime SemPtr = UnsafePointer[Int64, MutAnyOrigin]


@extern("mjs_sem_init")
def mjs_sem_init(initial: Int32, out_slot: SemSlot) abi("C") -> Int32:
    ...


@extern("mjs_sem_post")
def mjs_sem_post(s: SemPtr) abi("C") -> Int32:
    ...


@extern("mjs_sem_wait")
def mjs_sem_wait(s: SemPtr) abi("C") -> Int32:
    ...


@extern("mjs_sem_wait_until")
def mjs_sem_wait_until(s: SemPtr, deadline_ns: UInt64) abi("C") -> Int32:
    ...


@extern("mjs_sem_try_wait")
def mjs_sem_try_wait(s: SemPtr) abi("C") -> Int32:
    ...


@extern("mjs_sem_destroy")
def mjs_sem_destroy(slot: SemSlot) abi("C") -> Int32:
    ...


def probe_sem_init(initial: Int32, out_slot: SemSlot) -> Int32:
    return mjs_sem_init(initial, out_slot)


def probe_sem_post(s: SemHandle) -> Int32:
    return mjs_sem_post(SemPtr(unsafe_from_address=Int(s)))


def probe_sem_wait(s: SemHandle) -> Int32:
    return mjs_sem_wait(SemPtr(unsafe_from_address=Int(s)))


def probe_sem_wait_until(s: SemHandle, dl: UInt64) -> Int32:
    return mjs_sem_wait_until(SemPtr(unsafe_from_address=Int(s)), dl)


def probe_sem_try_wait(s: SemHandle) -> Int32:
    return mjs_sem_try_wait(SemPtr(unsafe_from_address=Int(s)))


def probe_sem_destroy(slot: SemSlot) -> Int32:
    return mjs_sem_destroy(slot)
