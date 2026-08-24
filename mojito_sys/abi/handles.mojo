# mojito-sys S1 ABI — opaque native handles (issue #27).
#
# Spec §7.2 (opaque handles) and §25 (fds; ownership: move transfers, destroy
# closes exactly once, borrowed never closes).
#
# Ownership model (public contract):
#   - OpaqueNativeHandle is a raw pointer-sized handle to native state the
#     wrapper does not own.  It exposes a null sentinel (address 0) and a
#     borrow() of the raw pointer; it never frees the referent.
#   - OwnedFd owns a POSIX file descriptor.  A move (`^`) transfers ownership
#     to the destination, and the moved-from source is destroyed WITHOUT
#     closing (ownership transfer suppresses the source destructor).
#     dispose()/the destructor close EXACTLY ONCE, guarded by a monotone
#     flag: _disposed goes false->true at most once, which is what makes a
#     double-dispose externally detectable from the struct's own state and a
#     repeat dispose() a no-op.
#   - BorrowedFd references a descriptor it does not own.  It has NO
#     destructor, so it can never close anything; the underlying descriptor
#     remains the caller's to manage.
#
# Only the platform C ABI is used (libc close); no mojito dylib is required.
# The helper below is file-private; the public surface is the three structs.

from std.memory.unsafe_pointer import UnsafePointer

comptime HandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]

# Sentinel for "no descriptor" / moved-from / already-reset OwnedFd values.
comptime NO_FD: Int32 = -1

# ---------------------------------------------------------------------------
# POSIX close(2) via the C ABI.  Returns 0 on success, -1/errno on failure.
# ---------------------------------------------------------------------------
@extern("close")
def _fd_close(fd: Int32) abi("C") -> Int32:
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

    # Return the underlying pointer WITHOUT handing off ownership or
    # lifetime: the caller must not dispose what it does not own.
    def borrow(self) -> HandlePtr:
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

    def get(self) -> Int32:
        return self.fd

    def is_disposed(self) -> Bool:
        return self._disposed

    # Close exactly once.  A repeat dispose() is a no-op (the monotone flag
    # is already set), so a double-dispose cannot close a descriptor that the
    # OS has reissued to something else.
    def dispose(mut self):
        if not self._disposed:
            self._disposed = True
            _ = _fd_close(self.fd)

    # Destructor: close only if the caller has not explicitly disposed.  On a
    # moved-from source the compiler suppresses this destructor (ownership
    # moved to the destination), which is what makes a move a transfer.
    def __del__(deinit self):
        self.dispose()


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