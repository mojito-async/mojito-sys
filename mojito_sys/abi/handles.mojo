# mojito-sys S1 ABI — opaque native handles (issue #27).
#
# Spec §7.2 (opaque handles) and §25 (fds; ownership: move transfers, destroy
# closes exactly once, borrowed never closes).
#
# Module placement note (spec §4): this harness live under abi/ so it can be
# imported early by the S1 lanes; the fd wrappers (OwnedFd/BorrowedFd) are
# expected to migrate up to io/handle.mojo once the io/ package lands.  The
# opaque-pointer and ownership semantics are unchanged by that move.
#
# Ownership model (public contract):
#   - OpaqueNativeHandle is a raw pointer-sized handle to native state the
#     wrapper does not own.  It exposes a null sentinel (address 0) and a
#     pointer() that COPIES the address; the caller must not retain or free
#     the referent through it.
#   - OwnedFd owns a POSIX file descriptor.  A move (`^`) transfers ownership
#     to the destination, and the moved-from source is destroyed WITHOUT
#     closing (ownership transfer suppresses the source destructor).
#     dispose()/the destructor close EXACTLY ONCE: dispose() commits the
#     close (sets the monotone flag + resets to NO_FD) only when close(2)
#     reports success (rc == 0).  On a nonzero rc the flag stays clear so the
#     caller may retry dispose() (bounded retry; EINTR-safe by contract).  A
#     repeat dispose() after success is a no-op.
#   - detach() surrenders the descriptor to the caller without closing;
#     the OwnedFd is then inert (is_null, is_disposed, and its destructor is
#     a no-op).
#   - BorrowedFd references a descriptor it does not own; it has NO
#     destructor and never closes.
#
# Thread-safety (spec §25): dispose()/__del__/detach() are NOT thread-safe.
# Callers must serialize access to a single OwnedFd instance.
#
# Only the platform C ABI is used (libc symbol close/fcntl/dup); the ms_
# Mojo-side names avoid clashing with Mojo stdlib's own close bindings.

from std.memory.unsafe_pointer import UnsafePointer

comptime HandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
#
# Origin choice (issue #45): this is EXACTLY spec §7.2's sketch and matches
# sibling UserdataPtr (callbacks.mojo).  MutUntrackedOrigin is correct here
# because HandlePtr never occupies an extern out-slot — the module's only
# @extern is ms_close(Int32).  The MutAnyOrigin out-slot doctrine documented
# in virtual_memory.mojo/stack.mojo (an UntrackedOrigin slot load can be
# hoisted ABOVE an opaque callee) applies only to pointers handed across an
# extern boundary; OpaqueNativeHandle never crosses one.

# Sentinel for "no descriptor" / moved-from / disposed / detached.
comptime NO_FD: Int32 = -1

# ---------------------------------------------------------------------------
# POSIX close(2) via the C ABI.  Returns 0 on success, -1/errno on failure.
# ---------------------------------------------------------------------------
@extern("close")
def ms_close(fd: Int32) abi("C") -> Int32:
    ...


# ---------------------------------------------------------------------------
# OpaqueNativeHandle — a raw native pointer with no ownership.
# ---------------------------------------------------------------------------
struct OpaqueNativeHandle:
    var ptr: HandlePtr

    # A default handle is null (the address-0 sentinel).
    def __init__(out self):
        var zero: Int = 0
        self.ptr = HandlePtr(unsafe_from_address=zero)

    # Wrap an existing non-null native pointer (no ownership transfer).
    def __init__(out self, p: HandlePtr):
        self.ptr = p

    # True when this handle holds the null sentinel (address 0).
    def is_null(self) -> Bool:
        return Int(self.ptr) == 0

    # Returns the raw address.  This is a COPY, not a transfer: the caller
    # must not keep or free the referent through the returned pointer.
    def pointer(self) -> HandlePtr:
        return self.ptr


# ---------------------------------------------------------------------------
# OwnedFd — owns a POSIX file descriptor; move transfers, destroy closes
# exactly once.
# ---------------------------------------------------------------------------
struct OwnedFd(Movable):
    var fd: Int32
    var _disposed: Bool

    # Wrap a descriptor and take ownership.
    def __init__(out self, fd_: Int32):
        self.fd = fd_
        self._disposed = False

    # A null/moved-from OwnedFd: no descriptor, marked disposed (so destroy
    # never touches fd = NO_FD).
    def __init__(out self):
        self.fd = NO_FD
        self._disposed = True

    def is_null(self) -> Bool:
        return self.fd < 0

    # Current descriptor, or NO_FD once disposed/detached/moved-from.
    def get(self) -> Int32:
        return self.fd

    def is_disposed(self) -> Bool:
        return self._disposed

    # A safe, non-owning view of the current descriptor; the returned
    # BorrowedFd has no destructor and never closes.
    def borrow(self) -> BorrowedFd:
        return BorrowedFd(self.fd)

    # Close exactly once.  On success (rc == 0) the descriptor is closed, the
    # monotone flag is set, and the held fd resets to NO_FD; a repeat
    # dispose() is then a no-op returning 0.  On a nonzero rc (including
    # EINTR) the flag stays clear and the fd is unchanged, so the caller may
    # retry.  Destructor callers ignore the status.
    def dispose(mut self) -> Int32:
        if self._disposed:
            return 0
        var rc = ms_close(self.fd)
        if rc == 0:
            self._disposed = True
            self.fd = NO_FD
        return rc

    # Detach the descriptor from the owned value WITHOUT closing: the caller
    # takes ownership of the returned fd.  This OwnedFd is then inert
    # (is_disposed == true, get() == NO_FD, destructor is a no-op).
    def detach(mut self) -> Int32:
        var retained = self.fd
        self.fd = NO_FD
        self._disposed = True
        return retained

    # Destructor: close unless the caller already disposed/detached.  On a
    # moved-from source the compiler suppresses this destructor (ownership
    # moved to the destination), which is what makes a move a transfer.  The
    # returned status is deliberately unused on the destructor path.
    def __del__(deinit self):
        _ = self.dispose()


# ---------------------------------------------------------------------------
# BorrowedFd — references a descriptor it does not own; never closes.
# ---------------------------------------------------------------------------
struct BorrowedFd:
    var fd: Int32

    def __init__(out self, fd_: Int32):
        self.fd = fd_

    def is_null(self) -> Bool:
        return self.fd < 0

    def get(self) -> Int32:
        return self.fd

    # Intentionally NO __del__: a borrow must never close the descriptor.