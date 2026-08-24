# mojito-sys ABI error representation — S1.3 (mojito-sys #26).
#
# A compact platform-neutral error carrier: an OS/generic domain plus a
# raw code. Mojo 1.0.0b2 has no enum sugar, so the domain tags are comptime
# struct members (POSIX, MACH, INTERNAL, WIN32, API); equality is by value,
# which also makes them safe to copy and compare by `==`.
#
# `SysError.to_string()` is a diagnostic aid ONLY — it is explicitly off the
# hot path. POSIX errno codes follow macOS (darwin) conventions; the message
# table here names only the common codes a synchronous OS call is likely to
# surface. Documentation of the darwin mappings lives beside the table.
#
# Design rule SYS-4 holds: `SysError` construction and `ok()` allocate
# nothing; `to_string()` is the sole allocating method and is off the hot
# path.


# An error domain discriminator. Values are b2 comptime members; the domain
# identity is the `value` field (compared via `==`). New domains must keep
# `value` unique.
struct ErrorDomain(ImplicitlyCopyable):
    var value: Int32

    comptime POSIX = ErrorDomain(0)
    comptime MACH = ErrorDomain(1)
    comptime INTERNAL = ErrorDomain(2)
    comptime WIN32 = ErrorDomain(3)
    comptime API = ErrorDomain(4)

    def __init__(out self, value: Int32):
        self.value = value

    # Value-type equality: two domains are equal iff their identity codes
    # match. This is what lets callers write `err.domain == ErrorDomain.POSIX`.
    def __eq__(self, other: ErrorDomain) -> Bool:
        return self.value == other.value


# A platform-neutral error value: `domain` names the source, `code` the raw
# error number within that domain (errno for POSIX). Construction never
# raises and allocates nothing, so `SysError` is safe to build on hot paths.
struct SysError:
    var domain: ErrorDomain
    var code: Int32

    def __init__(out self, domain: ErrorDomain, code: Int32):
        self.domain = domain
        self.code = code

    # Creates a POSIX-domain error from a raw errno.
    @staticmethod
    def from_posix(errno: Int32) -> SysError:
        return SysError(ErrorDomain.POSIX, errno)

    # True when the error represents no failure (code 0).
    def ok(self) -> Bool:
        return self.code == 0

    # Human-readable, diagnostic-only formatting. Off the hot path.
    #
    # darwin (macOS) errno values named by this table (numerically equal on
    # Linux, but the table is not exhaustive — unlisted codes fall back to a
    # numeric form):
    #   ENOENT = 2   (No such file or directory)
    #   EINTR  = 4   (Interrupted system call)
    #   ENOMEM = 12  (Cannot allocate memory)
    #   EACCES = 13  (Permission denied)
    #   EAGAIN = 35  (Resource temporarily unavailable)
    def to_string(self) -> String:
        if self.domain.value == 0:
            if self.code == 2:
                return "ENOENT (errno " + String(self.code) + ")"
            elif self.code == 4:
                return "EINTR (errno " + String(self.code) + ")"
            elif self.code == 12:
                return "ENOMEM (errno " + String(self.code) + ")"
            elif self.code == 13:
                return "EACCES (errno " + String(self.code) + ")"
            elif self.code == 35:
                return "EAGAIN (errno " + String(self.code) + ")"
            return "POSIX errno " + String(self.code)
        return (
            "domain " + String(self.domain.value) + " code " + String(self.code)
        )