# mojito-sys S1.13 — dynamic library loading (issue #46).
#
# Spec §4 places dynlib.mojo under abi/. Issue #46 disposition path A lands
# the minimal surface:
#   - dlopen/dlsym/dlclose + dlerror bound DIRECTLY from libc (@extern) —
#     no mjs_* C helpers, so native/ and exports.txt are unchanged by this
#     lane;
#   - RTLD_* mode constants carrying their POSIX values;
#   - explicit close-once ownership echoing §7.2/§25 (the OwnedFd
#     discipline: dispose commits exactly once on rc == 0, a repeat dispose
#     is a no-op 0, a move `^` transfers ownership and suppresses the
#     source destructor);
#   - deterministic missing-lib / missing-symbol / misuse errors.
#
# Why centralize what six spike drivers hand-rolled: every driver (t8-t13)
# declared its own private @extern("dlopen") because no behavioral spec
# existed; consumers DO need dynamic resolution for dlsym-visible exports
# (the spikes proved fn-pointer limits make statically linking every future
# export impractical), so the binding belongs in the package, not in each
# consumer.
#
# dlsym absence detection follows POSIX dlerror discipline: dlerror() is
# consumed BEFORE the call to clear sticky state, then consumed again after;
# a nonzero post-call pointer (or a NULL address) means the symbol was not
# found. Symbols whose true address is 0 are reported as absent — documented
# determinism, not an oversight.
#
# b2 conventions (issue #29 workaround, same as memory/virtual_memory.mojo):
# this module lowers @extern bindings AND hosts raising members of a
# (Movable) struct, therefore NO String literal reaches any `raise
# Error(...)` payload here — every message piece is decoded at RUNTIME from
# Int-packed ASCII (_unpack), exactly like mojito_sys.abi.errors.
# Raw ms_* externs are importable but NOT for caller use; prefer
# open_library()/main_library()/DynamicLibrary.resolve().

from std.memory import stack_allocation

comptime RTLD_LAZY: Int32 = 1
comptime RTLD_NOW: Int32 = 2

# Relocation visibility scope at load time. RTLD_LOCAL = 0 means "default";
# kept explicit so call sites never rely on the bare-0 convention.
comptime RTLD_LOCAL: Int32 = 0
comptime RTLD_GLOBAL: Int32 = 256

# Longest library/symbol name marshalled onto the stack staging buffer
# (NUL terminator included). Longer names fail with a deterministic error
# rather than truncating silently.
comptime NAME_MAX: Int = 255


@extern("dlopen")
def ms_dlopen(path: Int, mode: Int32) abi("C") -> Int:
    ...

@extern("dlsym")
def ms_dlsym(handle: Int, name: Int) abi("C") -> Int:
    ...

@extern("dlclose")
def ms_dlclose(handle: Int) abi("C") -> Int32:
    ...

# POSIX dlerror: returns the address of a NUL-terminated diagnostic for the
# last failing dl call on THIS thread, or 0; reading CONSUMES the message.
@extern("dlerror")
def ms_dlerror() abi("C") -> Int:
    ...


# Little-endian packed-ASCII decoder (same shape as errors.mojo's): byte 0
# is the first character; the string ends at the first zero byte. Runtime
# construction only — this is what keeps String data out of raise-payload
# lowering (issue #29). Straight-line: the String("") seed never crosses a
# control-flow merge on its way into a payload.
def _unpack(v: Int) -> String:
    var s = String("")
    var rest = v
    while rest != 0:
        s += chr(rest & 0xFF)
        rest >>= 8
    return s


# "dlopen failed: <dlerror text>" — the loader's own diagnostic appended.
# b2 (issue #29 family, this lane): message pieces are concatenated inside
# this NON-raising builder from Int-packed chunks and a raw C pointer;
# String-typed parameters flowing through a raise path crash the compiler,
# pointer-sized Ints do not.
def _msg_open_fail(errp: Int) -> String:
    var s = _unpack(0x206E65706F6C64) + _unpack(0x3A64656C696166) + _unpack(0x20)
    if errp != 0:
        var q = UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=errp)
        var i = 0
        while q[i] != 0:
            s += chr(Int(q[i]))
            i += 1
    return s


# "dlsym failed: <name>" — the queried symbol's name appended from its
# staged NUL-terminated address (same b2 workaround as _msg_open_fail).
def _msg_sym_fail(name_addr: Int) -> String:
    var s = _unpack(0x66206D79736C64) + _unpack(0x203A64656C6961)
    if name_addr != 0:
        var q = UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=name_addr)
        var i = 0
        while q[i] != 0:
            s += chr(Int(q[i]))
            i += 1
    return s


# "resolve on disposed library" — deterministic misuse diagnostic.
def _msg_disposed() -> String:
    # Step-wise concatenation only (see _msg_name_too_long note).
    var s = _unpack(0x65766C6F736572)
    s += _unpack(0x736964206E6F20)
    s += _unpack(0x6C206465736F70)
    s += _unpack(0x797261726269)
    return s


# "library or symbol name exceeds 255 bytes" — deterministic NAME_MAX
# rejection diagnostic. NOTE: b2 accepts this helper called from resolve()
# but NOT from open_library() — raising the payload from THAT frame crashes
# the compiler, so open_library enforces the bound through its own dedicated
# raising frame (_reject_over_name_max) instead.
def _msg_name_too_long() -> String:
    var s = _unpack(0x7972617262696C)
    s += _unpack(0x6D797320726F20)
    s += _unpack(0x6D616E206C6F62)
    s += _unpack(0x65656378652065)
    s += _unpack(0x20353532207364)
    s += _unpack(0x7365747962)
    return s



# Fill `buf` (owned by the CALLER's frame) with the NUL-terminated bytes of
# `s` and return its address. The split exists so the buffer outlives the
# dl* call it feeds: an address into a callee's own stack_allocation frame
# is dangling the moment the callee returns (dyld's stack traffic clobbers
# it — observed as an empty path reaching dlopen).
def _fill(buf: UnsafePointer[Byte, MutAnyOrigin], s: String) -> Int:
    var i = 0
    for ch in s:
        buf[i] = Byte(ord(ch))
        i += 1
    buf[i] = Byte(0)
    return Int(buf)


# Open the shared library named `name` (soname or path, per dlopen(3)).
# Raises a deterministic "dlopen failed" error when the loader refuses.
#
# Blocking: yes — dyld loads/links the image and runs initializers on first
#   load; even refcount hits take loader locks.
# Allocation: none on success (the name stages on the stack); failure
#   allocates the diagnostic String only, off any hot path.
# Task-aware: no — an OS-blocking call; invoke from task contexts only where
#   a blocking pause is tolerated (init/teardown).
# Deterministic NAME_MAX rejection for open_library(): lives in ITS OWN
# raising frame because b2 crashes when a payload built here is raised from
# open_library()'s frame directly (helper-call or inline alike).
def _reject_over_name_max(name: String) raises:
    if len(name) > NAME_MAX:
        # "library or symbol name exceeds 255 bytes"
        var s = _unpack(0x7972617262696C)
        s += _unpack(0x6D797320726F20)
        s += _unpack(0x6D616E206C6F62)
        s += _unpack(0x65656378652065)
        s += _unpack(0x20353532207364)
        s += _unpack(0x7365747962)
        raise Error(s)


def open_library(name: String, mode: Int32) raises -> DynamicLibrary:
    # NAME_MAX guard BEFORE staging: _fill writes len(name)+1 bytes into the
    # 256-byte stack buffer unconditionally, so a >255-byte name would
    # overrun this frame. Same deterministic message resolve() enforces.
    _reject_over_name_max(name)
    var buf = stack_allocation[256, Byte]()
    var h = ms_dlopen(_fill(buf, name), mode)
    if h == 0:
        # Deterministic missing-lib error: fixed prefix + the loader's own
        # dlerror text ("image not found" et al), all runtime-built.
        raise Error(_msg_open_fail(ms_dlerror()))
    return DynamicLibrary.unsafe_takeownership(h)


# A handle over the MAIN program image itself (dlopen(NULL)), so callers can
# resolve symbols exported by the host process (or any loaded library under
# flat lookup) without naming a file.
#
# Blocking: yes — same dyld lock traffic as open_library (no file I/O).
# Allocation: none.
# Task-aware: no — see open_library.
def main_library(mode: Int32) raises -> DynamicLibrary:
    var h = ms_dlopen(0, mode)
    if h == 0:
        raise Error(_msg_open_fail(ms_dlerror()))
    return DynamicLibrary.unsafe_takeownership(h)


# An owned handle over a dynamically loaded library. Move (`^`) transfers
# ownership; destroy/dispose closes EXACTLY ONCE (§7.2/§25). Not implicitly
# copyable — two live copies would double-close.
struct DynamicLibrary(Movable):
    var handle: Int
    var _closed: Bool

    # Default value: the null sentinel, already disposed. Deliberately the
    # ONLY public constructor — a raw-int ctor would let callers alias one
    # OS handle across two values that each close "exactly once"
    # (use-after-unmap while symbols live). open_library()/main_library()
    # are the sole paths to a live handle.
    #
    # Blocking: no. Allocation: none. Task-aware: no.
    def __init__(out self):
        self.handle = 0
        self._closed = True

    # MUST NOT be called outside mojito_sys/abi/dynlib.mojo. Escape hatch
    # for the module's own open_library()/main_library(): adopts a raw
    # dlopen handle and takes close-once ownership. Calling it with a handle
    # you do not exclusively own (e.g. one already wrapped elsewhere) breaks
    # the exactly-once close discipline — double dlclose / use-after-unmap.
    #
    # Blocking: no. Allocation: none. Task-aware: no.
    @staticmethod
    def unsafe_takeownership(handle_: Int) -> Self:
        var lib = Self()
        lib.handle = handle_
        lib._closed = False
        return lib^

    # True when this handle holds the null sentinel (never-opened or closed).
    #
    # Blocking: no. Allocation: none. Task-aware: no.
    def is_null(self) -> Bool:
        return self.handle == 0

    # True once dispose() has committed (or the handle was never opened).
    #
    # Blocking: no. Allocation: none. Task-aware: no.
    def is_disposed(self) -> Bool:
        return self._closed

    # Resolve `name` to its runtime address through this library's lookup
    # scope. Raises a deterministic "dlsym failed: <name>" error when absent
    # (see the dlerror discipline in the module header), and a deterministic
    # misuse error after dispose().
    #
    # Blocking: possibly — the query takes dyld locks; a first-time lazy
    #   lookup can trigger link work.
    # Allocation: none on success; the error path allocates the diagnostic.
    # Task-aware: no — treat as blocking-capable from task contexts.
    def resolve(self, name: String) raises -> Int:
        if self._closed or self.handle == 0:
            # "resolve on disposed library"
            raise Error(_msg_disposed())
        if len(name) > NAME_MAX:
            # "library or symbol name exceeds 255 bytes"
            raise Error(_msg_name_too_long())
        # Clear sticky thread-local state FIRST, then distinguish absence
        # by the post-call dlerror pointer (POSIX dlsym contract).
        _ = ms_dlerror()
        var buf = stack_allocation[256, Byte]()
        var nptr = _fill(buf, name)
        var addr = ms_dlsym(self.handle, nptr)
        var errp = ms_dlerror()
        if errp != 0 or addr == 0:
            # Deterministic missing-symbol error: fixed prefix + the name,
            # all runtime-built.
            raise Error(_msg_sym_fail(nptr))
        return addr

    # Close exactly once (echoes OwnedFd.dispose): on dlclose success (rc == 0)
    # the monotone flag commits, the handle resets to the null sentinel, and a
    # repeat dispose() is a no-op returning 0. On a nonzero rc the flag stays
    # clear and the handle is unchanged so the caller may retry. Returns the
    # dlclose status.
    #
    # Blocking: briefly — dlclose may unmap the image under loader locks.
    # Allocation: none.
    # Task-aware: no.
    def dispose(mut self) -> Int32:
        if self._closed or self.handle == 0:
            return 0
        var rc = ms_dlclose(self.handle)
        if rc == 0:
            self._closed = True
            self.handle = 0
        return rc

    # Destructor: close unless already disposed. On a moved-from source the
    # compiler suppresses this destructor (ownership moved to the
    # destination), which is what makes a move a transfer. The status is
    # deliberately unused on the destructor path.
    #
    # Blocking: as dispose(). Allocation: none. Task-aware: no.
    def __del__(deinit self):
        _ = self.dispose()
