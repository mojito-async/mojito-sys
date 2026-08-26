# mojito-sys S2.2 — raw mjs_thread_* FFI bindings (issue #49).
#
# LEAF MODULE (b2 WORKAROUND #49): this file deliberately contains ONLY
# @extern declarations and the comptime pointer aliases they need — no
# imports, no structs, no raise sites. b2 1.0.0b2's cross-module lowering
# misbinds register arguments of an extern call when the DECLARING module
# also hosts Movable structs with extern-calling methods and/or imports
# raising machinery (mojito_sys.abi.errors): the callee received
# `userdata` in BOTH the entry and userdata argument slots of
# mjs_thread_spawn (reproduced under lldb; see the conformance suite
# header). Pure-extern leaf modules are proven safe by the s1 precedents
# (memory/stack.mojo, memory/virtual_memory.mojo), so the bindings live
# here and the NativeThread wrapper imports them.
#
#
# NEVER-INLINE INVARIANT: the probe_* shims below are the ONLY sanctioned
# call path into the mjs_thread_* bindings and MUST stay tiny, non-raising,
# aggregate-free, and free of @always_inline at every call site. If an
# inliner ever merges a probe into a frame that reads an aggregate or
# computes a pointer argument across a data-dependent merge, the register
# misbind returns (entry/userdata collapse; lldb-proven). See thread.mojo's
# WORKAROUND block for the full trigger matrix.
# These symbols are NOT for caller use; prefer spawn_native_thread() /
# join() / detach() / native_thread_id() in mojito_sys.thread.thread.
# Out-slots are UnsafePointer[..., MutAnyOrigin]: the pointer escapes into
# an opaque callee, and MutAnyOrigin pins the post-call slot load AFTER
# the call.

# Opaque mjs_thread* handle (SYS-3): never dereferenced Mojo-side; produced
# by mjs_thread_spawn, consumed (NULLed by zero) on the C side. Carried as
# a RAW MACHINE WORD (Int64) — see thread.mojo's b2 WORKAROUND note.
comptime ThreadHandle = Int64

# mjs_thread_spawn/join/detach all take mjs_thread** slots; declared here
# as Int64 cells (the machine word holding the handle address).
comptime HandleSlot = UnsafePointer[Int64, MutAnyOrigin]

# Code address of a `long (*)(void *)` entry (ms_thread_entry). A bare Mojo
# function value cannot be converted to this; use the @export +
# entry_pointer recipe documented in thread.mojo. Byte pointee is a
# formality — the slot is a code address, never dereferenced through it.
comptime CThreadEntry = UnsafePointer[Byte, MutAnyOrigin]

# void* userdata carrier handed to the entry untouched. Int64 pointee is
# the recommended view (cells-style scratch); any pointer bitcast-safely
# converts at the call site. DISTINCT pointee types for entry/userdata:
# with two adjacent identically-typed UnsafePointer[NoneType] parameters,
# the misbind above reproduces even minimized (#49).
comptime UserdataPtr = UnsafePointer[Int64, MutAnyOrigin]

# const char* NUL-terminated name; a null pointer encodes "unnamed".
comptime NamePtr = UnsafePointer[Byte, MutAnyOrigin]

# mjs_thread_join's long* out-result slot (entry status).
comptime StatusSlot = UnsafePointer[Int64, MutAnyOrigin]


@extern("mjs_thread_spawn")
def mjs_thread_spawn(
    entry: CThreadEntry,
    userdata: UserdataPtr,
    stack_size: Int,
    name: NamePtr,
    out_handle: HandleSlot,
) abi("C") -> Int32:
    ...


@extern("mjs_thread_join")
def mjs_thread_join(
    handle_slot: HandleSlot,
    out_result: StatusSlot,
) abi("C") -> Int32:
    ...


@extern("mjs_thread_detach")
def mjs_thread_detach(handle_slot: HandleSlot) abi("C") -> Int32:
    ...


@extern("mjs_thread_self_id")
def mjs_thread_self_id() abi("C") -> UInt64:
    ...


@extern("mjs_thread_set_name")
def mjs_thread_set_name(name: NamePtr) abi("C") -> Int32:
    ...


# ---- non-raising call shims (b2 WORKAROUND #49, layer 2) --------------------
#
# Same-module extern calls pass register arguments correctly (proven by the
# s1 precedents and the minimized repro matrix); it is the CROSS-MODULE call
# out of a module that also hosts Movable types / raising machinery that
# misbinds. These shims therefore perform EVERY mjs_thread_* invocation
# right here in the pure leaf and return the raw C rc; mojito_sys.thread.thread
# decodes/raises only AFTER the call has returned, so its spawn path touches
# no raise machinery at all.


def probe_spawn(
    entry: CThreadEntry,
    userdata: UserdataPtr,
    stack_size: Int,
    name: NamePtr,
    out_handle: HandleSlot,
) -> Int32:
    return mjs_thread_spawn(entry, userdata, stack_size, name, out_handle)


def probe_join(handle_slot: HandleSlot, out_result: StatusSlot) -> Int32:
    return mjs_thread_join(handle_slot, out_result)


def probe_detach(handle_slot: HandleSlot) -> Int32:
    return mjs_thread_detach(handle_slot)


def probe_self_id() -> UInt64:
    return mjs_thread_self_id()


def probe_set_name(name: NamePtr) -> Int32:
    return mjs_thread_set_name(name)
