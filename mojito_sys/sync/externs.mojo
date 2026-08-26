# mojito-sys S3.1 — raw mjs_mutex_* FFI bindings (issue #57).
#
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
