# mojito-sys S6.1 — native IO handles (issue #73).
#
# Spec §27.1: the readiness interface consumes `NativeIoHandle` as the
# raw descriptor/HANDLE value type (`register(mut self, handle:
# NativeIoHandle, ...)`). Spec §25 ownership semantics for the io
# wrapper family: move transfers, borrow never closes, moved-from state
# detectable in debug.
#
# NativeIoHandle is deliberately NON-OWNING: it carries a raw descriptor /
# HANDLE value and closes NOTHING on destruction (no destructor at all).
# Ownership lives one layer up in the §25 family (OwnedFd/BorrowedFd,
# issue #42); a poller that receives a NativeIoHandle borrows it for the
# duration of a registration and never closes it.
#
# Blocking behavior (SYS-5): every operation on NativeIoHandle is pure
# integer bookkeeping — no syscalls, never blocks.
#
# Zero new C symbols: this module binds no C entry points; exports.txt is
# unchanged by design.

# Sentinel shared with the S1 ABI fd wrappers (mojito_sys.abi.handles):
# "no descriptor" / moved-from / invalid.
comptime NO_FD: Int32 = -1


# ---------------------------------------------------------------------------
# NativeIoHandle — raw descriptor/HANDLE value type (spec §27.1).
# ---------------------------------------------------------------------------
struct NativeIoHandle(Movable):
    """A raw, non-owning IO handle value (POSIX fd or platform HANDLE).

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
