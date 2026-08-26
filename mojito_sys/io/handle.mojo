# mojito-sys S6.1 — native IO handles (issue #73).
#
# Spec §27.1: the readiness interface consumes `NativeIoHandle` as the
# raw descriptor value type (`register(mut self, handle: NativeIoHandle,
# ...)`). Spec §25 ownership semantics for the io wrapper family: move
# transfers, borrow never closes, moved-from state detectable in debug.
#
# Scope: NativeIoHandle storage is Int32 — POSIX fd currency ONLY.  The
# Win64 HANDLE/SOCKET values are pointer-sized, not Int32, and belong to
# the §25 OwnedSocket/OwnedHandle family, not here.
#
# NativeIoHandle is deliberately NON-OWNING: it carries a raw Int32 fd
# value and closes NOTHING on destruction (no destructor at all).
# Ownership lives one layer up in the §25 family (OwnedFd/BorrowedFd,
# issue #42); a poller that receives a NativeIoHandle borrows it for the
# duration of a registration and never closes it.
#
# Blocking behavior (SYS-5): every operation on NativeIoHandle is pure
# integer bookkeeping — no syscalls, never blocks.
#
# Zero new C symbols: the only C binding here is the platform libc
# close(2) (used by OwnedFd); it is an @extern to libc and adds NO export
# to libmojito_sys.dylib — exports.txt is unchanged by design.

# Sentinel: "no descriptor" / moved-from / invalid.  Owned by this module
# since the fd wrappers migrated here (issue #42).
comptime NO_FD: Int32 = -1


# ---------------------------------------------------------------------------
# NativeIoHandle — raw Int32 POSIX fd value type (spec §27.1).
# ---------------------------------------------------------------------------
struct NativeIoHandle(Movable):
    """A raw, non-owning IO handle value: Int32 POSIX fd currency ONLY.

    Win64 HANDLE/SOCKET values are pointer-sized, not Int32; they belong
    to the §25 OwnedSocket/OwnedHandle family and are out of scope here.

    Contract (spec §25/§27.1):
      - Move (`^`) TRANSFERS the token: the destination keeps the exact
        raw value; the source drops to the NO_FD sentinel.
      - borrow() yields another non-owning view of the same raw value;
        nothing in this type ever issues close(2), so a borrow NEVER
        closes the underlying descriptor.
      - The moved-from / default state is detectable in debug builds:
        is_valid() reports False and get() returns NO_FD (-1) after a
        move-out or on a default-constructed value.

    Blocking behavior (SYS-5): never blocks; no syscalls.
    """

    var fd: Int32

    # An invalid/moved-from-shaped handle: no descriptor.
    def __init__(out self):
        self.fd = NO_FD

    # Wrap an existing raw descriptor/HANDLE value (no ownership taken,
    # no liveness syscall performed).
    def __init__(out self, fd_: Int32):
        self.fd = fd_

    # Move constructor: transfer the token; mark the source moved-from so
    # its invalidity is detectable via is_valid()/get() in debug builds.
    fn __moveinit__(out self, owned existing: Self):
        self.fd = existing.fd
        existing.fd = NO_FD

    # True while this handle still carries a usable raw value (False for
    # default-constructed and moved-from values).
    def is_valid(self) -> Bool:
        return self.fd >= 0

    # The raw descriptor/HANDLE value, or NO_FD once invalid/moved-from.
    def get(self) -> Int32:
        return self.fd

    # Another non-owning view of the same raw value.  Never closes: both
    # views are plain values, and no member of this type ever closes.
    def borrow(self) -> Self:
        return Self(self.fd)

    # Move-out: TRANSFERS the token to the returned handle and leaves THIS
    # value moved-from (NO_FD).  Unlike the `^` move — whose source the
    # compiler rejects as uninitialized after the transfer — take() keeps
    # the source initialized-but-invalid, so the moved-from state stays
    # readable and assertable in debug builds (is_valid() == False,
    # get() == NO_FD).
    def take(mut self) -> Self:
        var out = Self(self.fd)
        self.fd = NO_FD
        return out^


@extern("close")
def ms_close(fd: Int32) abi("C") -> Int32:
    ...


# ---------------------------------------------------------------------------
# OwnedFd — owns a POSIX file descriptor; move transfers, destroy closes
# exactly once.  (Migrated verbatim from mojito_sys/abi/handles.mojo —
# issue #42; semantics unchanged.)
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
# (Migrated verbatim from mojito_sys/abi/handles.mojo — issue #42.)
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
