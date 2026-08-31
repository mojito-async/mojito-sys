# spike/runtime/externs_leaf.mojo — M1.3 (#126) raw extern bindings, LEAF
# MODULE.
#
# Same discipline as every other externs.mojo in this repo (precedent #49,
# echoed most recently in spike/abi/externs_leaf.mojo for #124): ONLY
# @extern declarations, the comptime pointer aliases they need, and tiny
# non-raising probe_* call shims — no imports, no Movable structs, no
# raise sites, no control flow. This is the direct-call surface #126 is
# actually about: pthread_create/join, pthread_key_*, kqueue/kevent and
# epoll/eventfd called with NO mojito-sys C layer anywhere in the chain
# (not even mjs_thread.c's trampoline — this leg calls pthread_create
# itself, with a Mojo abi("C") function as the start routine).
#
# DISTINCT-POINTEE-TYPE DISCIPLINE (b2 WORKAROUND precedent #49): the
# original #49 repro was two ADJACENT UnsafePointer[NoneType, ...]
# parameters (entry, userdata) getting their registers collapsed onto one
# value. mojito_sys/thread/externs.mojo's fix — give adjacent opaque-
# pointer parameters DISTINCT pointee types (Byte for a code address, Int64
# for a data cell) — is followed here for pthread_create's four arguments
# (thread-out, attr, start_routine, arg) even though attr is always NULL in
# this spike (no ThreadOptions/attr-object round trip — #124 already proved
# pthread_attr_t byte-exact and real-round-tripped; re-proving it is not
# this leg's job). Two ADJACENT UnsafePointer[Byte, ...] (ByteBuf)
# parameters are NOT the same hazard: mojito_sys/io/externs.mojo already
# calls mjs_sockaddr_format4(addr: ByteBuf, out_buf: ByteBuf, ...) with two
# adjacent ByteBuf params in production, so kevent's changelist/eventlist/
# timeout (all ByteBuf) follow that precedent instead.
#
# KEVENT BYTE LAYOUT: ident@0 (u64), filter@8 (i16), flags@10 (u16),
# fflags@12 (u32), data@16 (i64), udata@24 (u64) — 32 bytes total. This is
# the layout spike/abi/types.mojo's Kevent struct already proved
# byte-exact against a live C oracle (spike/abi/FINDINGS.md, "kevent" row:
# size+offsets+round-trip PASS). Reusing that MEASURED fact here rather
# than re-deriving it; this file still owns its own byte pokes (no
# cross-spike-directory import — spike/ is not a package, see spike/abi's
# own precedent of duplicating LeafTimespec instead of importing
# types.mojo).
#
# EPOLL_EVENT BYTE LAYOUT: NOT hardcoded here, unlike kevent — #124's own
# FINDINGS.md flags this struct's AArch64-vs-x86-64 packing divergence as
# "unverified anywhere reachable from this repo, on any host" at the time
# that leg closed. Rather than guess, poller_epoll_test.mojo reads
# oracle_sizeof_epoll_event()/oracle_offset_epoll_event_{events,data}() at
# runtime and pokes/reads fields at the MEASURED offsets — see that file.

comptime ByteBuf = UnsafePointer[Byte, MutAnyOrigin]
comptime I32Slot = UnsafePointer[Int32, MutAnyOrigin]
comptime U64Slot = UnsafePointer[UInt64, MutAnyOrigin]

# Distinct pointee types for pthread_create's four parameters (see the
# DISTINCT-POINTEE-TYPE note above): out-thread (U64Slot), attr (I32Slot,
# always NULL here), start_routine (ByteBuf, a code address never
# dereferenced), arg (U64Slot reused — arg and out-thread are NOT
# adjacent in pthread_create's own parameter list, so this does not
# reproduce the adjacent-same-type hazard).
comptime PthreadTSlot = UnsafePointer[UInt64, MutAnyOrigin]
comptime PthreadAttrPtr = UnsafePointer[Int32, MutAnyOrigin]
comptime EntryCodePtr = UnsafePointer[Byte, MutAnyOrigin]
comptime ArgPtr = UnsafePointer[UInt64, MutAnyOrigin]

# ---- oracle.c: opaque pthread type facts + platform constants -------------

@extern("oracle_sizeof_pthread_t")
def oracle_sizeof_pthread_t() abi("C") -> UInt64: ...
@extern("oracle_alignof_pthread_t")
def oracle_alignof_pthread_t() abi("C") -> UInt64: ...
@extern("oracle_sizeof_pthread_key_t")
def oracle_sizeof_pthread_key_t() abi("C") -> UInt64: ...
@extern("oracle_alignof_pthread_key_t")
def oracle_alignof_pthread_key_t() abi("C") -> UInt64: ...

@extern("oracle_has_kqueue")
def oracle_has_kqueue() abi("C") -> Int32: ...
@extern("oracle_const_EVFILT_READ")
def oracle_const_EVFILT_READ() abi("C") -> Int32: ...
@extern("oracle_const_EVFILT_WRITE")
def oracle_const_EVFILT_WRITE() abi("C") -> Int32: ...
@extern("oracle_const_EVFILT_USER")
def oracle_const_EVFILT_USER() abi("C") -> Int32: ...
@extern("oracle_const_EV_ADD")
def oracle_const_EV_ADD() abi("C") -> UInt32: ...
@extern("oracle_const_EV_DELETE")
def oracle_const_EV_DELETE() abi("C") -> UInt32: ...
@extern("oracle_const_EV_CLEAR")
def oracle_const_EV_CLEAR() abi("C") -> UInt32: ...
@extern("oracle_const_EV_EOF")
def oracle_const_EV_EOF() abi("C") -> UInt32: ...
@extern("oracle_const_NOTE_TRIGGER")
def oracle_const_NOTE_TRIGGER() abi("C") -> UInt32: ...

@extern("oracle_has_epoll")
def oracle_has_epoll() abi("C") -> Int32: ...
@extern("oracle_const_EPOLLIN")
def oracle_const_EPOLLIN() abi("C") -> UInt32: ...
@extern("oracle_const_EPOLLOUT")
def oracle_const_EPOLLOUT() abi("C") -> UInt32: ...
@extern("oracle_const_EPOLLERR")
def oracle_const_EPOLLERR() abi("C") -> UInt32: ...
@extern("oracle_const_EPOLLHUP")
def oracle_const_EPOLLHUP() abi("C") -> UInt32: ...
@extern("oracle_const_EPOLLRDHUP")
def oracle_const_EPOLLRDHUP() abi("C") -> UInt32: ...
@extern("oracle_const_EPOLL_CTL_ADD")
def oracle_const_EPOLL_CTL_ADD() abi("C") -> Int32: ...
@extern("oracle_const_EPOLL_CTL_MOD")
def oracle_const_EPOLL_CTL_MOD() abi("C") -> Int32: ...
@extern("oracle_const_EPOLL_CTL_DEL")
def oracle_const_EPOLL_CTL_DEL() abi("C") -> Int32: ...
@extern("oracle_const_EFD_NONBLOCK")
def oracle_const_EFD_NONBLOCK() abi("C") -> Int32: ...
@extern("oracle_const_EFD_CLOEXEC")
def oracle_const_EFD_CLOEXEC() abi("C") -> Int32: ...
@extern("oracle_sizeof_epoll_event")
def oracle_sizeof_epoll_event() abi("C") -> UInt64: ...
@extern("oracle_alignof_epoll_event")
def oracle_alignof_epoll_event() abi("C") -> UInt64: ...
@extern("oracle_offset_epoll_event_events")
def oracle_offset_epoll_event_events() abi("C") -> UInt64: ...
@extern("oracle_offset_epoll_event_data")
def oracle_offset_epoll_event_data() abi("C") -> UInt64: ...
@extern("oracle_epoll_event_is_packed")
def oracle_epoll_event_is_packed() abi("C") -> Int32: ...

# ---- tools/migration_baseline/alloc_probe_shim.c: dyld-interposed malloc
# counter (§18's "measured, not asserted" allocation-count methodology,
# already used by M1.1's own baseline). Loaded via DYLD_INSERT_LIBRARIES +
# -Xlinker by spike/runtime/run.sh for the T6 (TLS get allocation-free)
# check only; macOS-only mechanism, declared unconditionally per the same
# #197-driven convention as the epoll externs above (never called on a
# host where the shim was not loaded).

@extern("mjs_alloc_probe_alloc_calls")
def mjs_alloc_probe_alloc_calls() abi("C") -> Int64: ...
@extern("mjs_alloc_probe_free_calls")
def mjs_alloc_probe_free_calls() abi("C") -> Int64: ...
@extern("mjs_alloc_probe_reset")
def mjs_alloc_probe_reset() abi("C"): ...

@extern("oracle_write_bytes")
def oracle_write_bytes(fd: Int32, buf: ByteBuf, count: UInt64) abi("C") -> Int64: ...

@extern("oracle_tls_set_from_c")
def oracle_tls_set_from_c(key: UInt64, value: UInt64) abi("C") -> Int32: ...
@extern("oracle_tls_get_from_c")
def oracle_tls_get_from_c(key: UInt64) abi("C") -> UInt64: ...
@extern("oracle_narrow_tls_key_roundtrips")
def oracle_narrow_tls_key_roundtrips(key: UInt64) abi("C") -> Int32: ...

# ---- s2-thread direct surface (issue #126, NO mjs_thread.c involved) ------

@extern("pthread_create")
def mjo_pthread_create(
    thread_out: PthreadTSlot,
    attr: PthreadAttrPtr,
    start_routine: EntryCodePtr,
    arg: ArgPtr,
) abi("C") -> Int32: ...

@extern("pthread_join")
def mjo_pthread_join(thread: UInt64, retval: U64Slot) abi("C") -> Int32: ...

@extern("pthread_self")
def mjo_pthread_self() abi("C") -> UInt64: ...

# ---- s2-tls direct surface (issue #126, NO mjs_tls.c involved) -------------

@extern("pthread_key_create")
def mjo_pthread_key_create(
    key_out: U64Slot, destructor: ByteBuf
) abi("C") -> Int32: ...

@extern("pthread_key_delete")
def mjo_pthread_key_delete(key: UInt64) abi("C") -> Int32: ...

@extern("pthread_getspecific")
def mjo_pthread_getspecific(key: UInt64) abi("C") -> UInt64: ...

@extern("pthread_setspecific")
def mjo_pthread_setspecific(key: UInt64, value: UInt64) abi("C") -> Int32: ...

# ---- s6-poller direct surface: kqueue (macOS/BSD), issue #126 -------------

@extern("kqueue")
def mjo_kqueue() abi("C") -> Int32: ...

@extern("kevent")
def mjo_kevent(
    kq: Int32,
    changelist: ByteBuf,
    nchanges: Int32,
    eventlist: ByteBuf,
    nevents: Int32,
    timeout: ByteBuf,
) abi("C") -> Int32: ...

# ---- s6-epoll direct surface: epoll + eventfd (Linux), issue #126 ---------
# Declared UNCONDITIONALLY on every platform (mojito-sys#197: no
# module-level conditional compilation for @extern — the untaken
# platform's declaration never links/JITs if it is never CALLED; the
# guard belongs at the call site via `comptime if`, matching
# spike/abi/externs_leaf.mojo's __errno_location precedent exactly).

@extern("epoll_create1")
def mjo_epoll_create1(flags: Int32) abi("C") -> Int32: ...

@extern("epoll_ctl")
def mjo_epoll_ctl(
    epfd: Int32, op: Int32, fd: Int32, event: ByteBuf
) abi("C") -> Int32: ...

@extern("epoll_wait")
def mjo_epoll_wait(
    epfd: Int32, events: ByteBuf, maxevents: Int32, timeout_ms: Int32
) abi("C") -> Int32: ...

@extern("eventfd")
def mjo_eventfd(initval: UInt32, flags: Int32) abi("C") -> Int32: ...

# ---- shared plumbing: pipe/close/read (proven extern-safe by #124) --------

@extern("pipe")
def mjo_pipe(fds: I32Slot) abi("C") -> Int32: ...

@extern("close")
def mjo_close(fd: Int32) abi("C") -> Int32: ...

@extern("read")
def mjo_read(fd: Int32, buf: ByteBuf, count: UInt64) abi("C") -> Int64: ...

# `write` is deliberately NOT declared here (mojito-sys#195: a custom
# @extern("write") conflicts with std.io's internal binding the moment
# BOTH are exercised in one compiled program, and every test file below
# uses print()). Use std.io.FileDescriptor.write() at call sites instead,
# exactly like spike/abi/libc_calls_test.mojo does.

# ---- non-raising call shims (leaf-module boundary, repo convention) -------

def probe_pthread_create(
    thread_out: PthreadTSlot,
    attr: PthreadAttrPtr,
    start_routine: EntryCodePtr,
    arg: ArgPtr,
) -> Int32:
    return mjo_pthread_create(thread_out, attr, start_routine, arg)

def probe_pthread_join(thread: UInt64, retval: U64Slot) -> Int32:
    return mjo_pthread_join(thread, retval)

def probe_pthread_self() -> UInt64:
    return mjo_pthread_self()

def probe_pthread_key_create(key_out: U64Slot, destructor: ByteBuf) -> Int32:
    return mjo_pthread_key_create(key_out, destructor)

def probe_pthread_key_delete(key: UInt64) -> Int32:
    return mjo_pthread_key_delete(key)

def probe_pthread_getspecific(key: UInt64) -> UInt64:
    return mjo_pthread_getspecific(key)

def probe_pthread_setspecific(key: UInt64, value: UInt64) -> Int32:
    return mjo_pthread_setspecific(key, value)

def probe_kqueue() -> Int32:
    return mjo_kqueue()

def probe_kevent(
    kq: Int32,
    changelist: ByteBuf,
    nchanges: Int32,
    eventlist: ByteBuf,
    nevents: Int32,
    timeout: ByteBuf,
) -> Int32:
    return mjo_kevent(kq, changelist, nchanges, eventlist, nevents, timeout)

def probe_epoll_create1(flags: Int32) -> Int32:
    return mjo_epoll_create1(flags)

def probe_epoll_ctl(epfd: Int32, op: Int32, fd: Int32, event: ByteBuf) -> Int32:
    return mjo_epoll_ctl(epfd, op, fd, event)

def probe_epoll_wait(
    epfd: Int32, events: ByteBuf, maxevents: Int32, timeout_ms: Int32
) -> Int32:
    return mjo_epoll_wait(epfd, events, maxevents, timeout_ms)

def probe_eventfd(initval: UInt32, flags: Int32) -> Int32:
    return mjo_eventfd(initval, flags)

def probe_pipe(fds: I32Slot) -> Int32:
    return mjo_pipe(fds)

def probe_close(fd: Int32) -> Int32:
    return mjo_close(fd)

def probe_read(fd: Int32, buf: ByteBuf, count: UInt64) -> Int64:
    return mjo_read(fd, buf, count)
