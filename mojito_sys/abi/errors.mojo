# mojito-sys ABI error representation — S1.3 (mojito-sys #26).
#
# A compact platform-neutral error carrier: an OS/generic domain plus a raw
# code within that domain. Mojo 1.0.0b2 has no enum sugar, so the domain
# tags are comptime struct members (POSIX, MACH, INTERNAL, WIN32, WSA, API);
# equality is by value, which also makes them safe to copy and compare by
#
# Spec §7.3 CONTRACT AMENDMENT, ratified per the #16/#19 amendment precedent
# and recorded here because docs/ is frozen while this shipped API is the
# authoritative record: the spec's `POSIX_ERRNO` domain tag ships as `POSIX`.
# Decided while the ABI was still unmerged (free then, ABI-breaking later).
# WSA is retained; `API` vs `INTERNAL` semantics are documented on
# `ErrorDomain` below.
#
# `SysError.to_string()` is a diagnostic aid ONLY — it is explicitly off the
# hot path, and its output is NOT a stable API; consumers must not parse it.
# POSIX errno names are HOST-SELECTED: darwin numbering on macOS targets,
# Linux numbering on Linux targets (`errno_name`). The two numberings differ
# for several codes (e.g. 35 = EAGAIN on darwin but EDEADLK on Linux); codes
# absent from the selected table fall back to a deterministic numeric form.


from std.sys import CompilationTarget

# Design rule SYS-4 holds: `SysError` construction, `ok()` and `from_rc()`
# allocate nothing; `to_string()` is the sole allocating method and is off
# the hot path.


# POSIX errno name tables for to_string(). b2 cannot materialize a
# `List[Tuple[Int32, String]]` into a runtime value (String payloads break
# the Movable requirement), so the codes and names are kept as index-aligned
# comptime lists and scanned in parallel — one table per supported host
# numbering, selected explicitly by `errno_name` below.
#
# darwin (macOS) numbering:
#   ENOENT = 2   EACCES = 13  EAGAIN = 35  ENOMEM = 12  EINTR  = 4
#   EINVAL = 22  EFAULT = 14  ENOTSUP = 45
def _unpack(v: Int) -> String:
    # Little-endian packed ASCII: byte 0 is the first character; the string
    # ends at the first zero byte. Straight-line construction only.
    var s = String("")
    var rest = v
    while rest != 0:
        s += chr(rest & 0xFF)
        rest >>= 8
    return s


# Names are stored as little-endian ASCII packed into Int constants (e.g.
# "EINVAL" -> bytes 45 49 56 41 4C -> 0x4C41564E4945) and selected by
# branching on Ints ONLY.
#
# b2 NOTE (issue #29): a String LITERAL that reaches a `raise Error(...)`
# payload through control flow (branch or loop merge — even via a helper,
# even cross-module, even @always_inline) SIGSEGVs the compiler when the
# raising member lives on a (Movable) struct in a module that also lowers
# @extern bindings (mojito_sys/memory/virtual_memory.mojo). Strings built at
# RUNTIME from Ints lower cleanly everywhere, so the names travel as Ints and
# are decoded straight-line here. The comments keep the table readable.


# Darwin-table scan. Returns "" for codes outside the darwin numbering.
def _errno_name_darwin(code: Int32) -> String:
    var packed = Int(0)
    var packed2 = Int(0)
    if code == 2:
        packed = 0x544E454F4E45  # "ENOENT"
    elif code == 13:
        packed = 0x534543434145  # "EACCES"
    elif code == 35:
        packed = 0x4E4941474145  # "EAGAIN" (EDEADLK = 11 here)
    elif code == 12:
        packed = 0x4D454D4F4E45  # "ENOMEM"
    elif code == 4:
        packed = 0x52544E4945  # "EINTR"
    elif code == 22:
        packed = 0x4C41564E4945  # "EINVAL"
    elif code == 14:
        packed = 0x544C55414645  # "EFAULT"
    elif code == 45:
        packed = 0x50555354_4F4E45  # "ENOTSUP"
    elif code == 63 or code == 36:
        # ENAMETOOLONG: darwin spells it 63, Linux 36 (both accepted here
        # so the decoded NAME is host-independent for this code; the
        # numeric value in to_string() still shows the raw host spelling).
        # 12 chars > one Int word, so the name travels as two aligned
        # words ("ENAMETOO" + "LONG"), still runtime-built from Ints.
        packed = 0x4F4F54454D414E45  # "ENAMETOO"
        packed2 = 0x474E4F4C  # "LONG"
    if packed2 != 0:
        return _unpack(packed) + _unpack(packed2)
    return _unpack(packed)


# Linux-table scan. Returns "" for codes outside the Linux numbering.
def _errno_name_linux(code: Int32) -> String:
    var packed = Int(0)
    if code == 2:
        packed = 0x544E454F4E45  # "ENOENT"
    elif code == 13:
        packed = 0x534543434145  # "EACCES"
    elif code == 11:
        packed = 0x4E4941474145  # "EAGAIN" (35 on darwin)
    elif code == 12:
        packed = 0x4D454D4F4E45  # "ENOMEM"
    elif code == 4:
        packed = 0x52544E4945  # "EINTR"
    elif code == 22:
        packed = 0x4C41564E4945  # "EINVAL"
    elif code == 14:
        packed = 0x544C55414645  # "EFAULT"
    elif code == 35:
        packed = 0x4B4C4441454445  # "EDEADLK" (11 on darwin)
    elif code == 95:
        packed = 0x50555354_4F4E45  # "ENOTSUP" (45 on darwin)
    return _unpack(packed)


# Host-selected errno name: the table follows the errno NUMBERING of the
# compilation target — darwin on macOS targets, Linux on Linux targets — so
# a colliding code such as 35 prints the name that is correct FOR THE HOST
# libc instead of a fixed numbering. Codes outside the selected table return
# "" and callers fall back to the deterministic numeric form ("POSIX errno
# N"); unsupported targets always take the numeric form. Diagnostic-only —
# see SysError.to_string().
#
# Blocking behavior (SYS-5): none — pure table scan, no syscalls.
# Allocation: builds one String; diagnostic-only path, never hot.
# Task-aware: no async or task interaction.
def errno_name(code: Int32) -> String:
    if CompilationTarget().is_macos():
        return _errno_name_darwin(code)
    if CompilationTarget().is_linux():
        return _errno_name_linux(code)
    return ""


def domain_name(value: Int32) -> String:
    var packed = Int(0)
    if value == 0:
        packed = 0x5849534F50  # "POSIX"
    elif value == 1:
        packed = 0x4843414D  # "MACH"
    elif value == 2:
        packed = 0x4C414E5245544E49  # "INTERNAL"
    elif value == 3:
        packed = 0x32334E4957  # "WIN32"
    elif value == 4:
        packed = 0x415357  # "WSA"
    elif value == 5:
        packed = 0x495041  # "API"
    return _unpack(packed)


# An error-domain discriminator. The domain is the `value` field (compared
# via `==`), kept unique so domains stay pairwise-distinguishable. A code of
# zero means "no failure" in EVERY domain; no domain may use 0 for a failure.
#
# Domain semantics:
#   POSIX    — POSIX errno codes from the C `errno` namespace (0 = no
#              error). Carries the raw positive errno; use `SysError.ok()`
#              for the success case.
#   MACH     — kern_return / mach_error codes from the macOS Mach kernel
#              (0 = success, nonzero = failure code).
#   INTERNAL — mojito-sys internal status codes (arbitrary nonzero failure
#              codes, 0 = success). For invariants and "cannot happen"
#              failures rather than OS surfaces.
#   WIN32    — GetLastError() codes on Windows (0 = success, else a Win32
#              error code).
#   WSA      — Winsock error codes (WSAEINTR=10004, WSAEBADF=10009, ...;
#              10001 + errno offset; 0 = success).
#   API      — mojito-sys public-API contract codes / caller-misuse codes,
#              stable and caller-facing across the ABI (0 = success).
#              Distinct from INTERNAL: API codes are a stable public
#              contract, INTERNAL codes are diagnostic.
#
# Domain id allocation policy (#44):
#   ids 0-15   — RESERVED for mojito-sys itself. 0-5 are allocated above;
#                6-15 are held so future built-in tags never collide with
#                anything downstream.
#   ids >= 16  — downstream extension band. Pick any unused id and treat it
#                as globally allocated FOREVER: never renumber or reuse it,
#                and keep code 0 = success inside your domain. There is no
#                registry — first writer of an id owns it by convention, so
#                choose high, scattered ids (e.g. a hash of your package
#                name) to minimize collision risk.
#   Negative ids are invalid and must never be minted.
# The Int32 constructor is public precisely so downstream libraries can
# mint extension-band domains; everything below 16 is mojito-sys's alone.
struct ErrorDomain(ImplicitlyCopyable):
    var value: Int32

    comptime POSIX = ErrorDomain(0)
    comptime MACH = ErrorDomain(1)
    comptime INTERNAL = ErrorDomain(2)
    comptime WIN32 = ErrorDomain(3)
    comptime WSA = ErrorDomain(4)
    comptime API = ErrorDomain(5)

    def __init__(out self, value: Int32):
        self.value = value

    # Value-type equality: two domains are equal iff their identity codes
    # match. This is what lets callers write `err.domain == ErrorDomain.POSIX`.
    def __eq__(self, other: ErrorDomain) -> Bool:
        return self.value == other.value


# A platform-neutral error value: `domain` names the source, `code` the raw
# error number within that domain (a POSIX errno for POSIX). Construction
# never raises and allocates nothing, so `SysError` is safe to build on hot
# paths. A code of 0 in ANY domain means "no failure".
struct SysError(ImplicitlyCopyable):
    var domain: ErrorDomain
    var code: Int32

    def __init__(out self, domain: ErrorDomain, code: Int32):
        self.domain = domain
        self.code = code

    # POSIX-domain error from a POSITIVE errno (the classic `errno` value
    # set by the C library, e.g. 2 = ENOENT). For values that already carry
    # the frozen negative-errno-return contract (see `from_rc`), use that
    # instead.
    @staticmethod
    def from_posix(errno: Int32) -> SysError:
        return SysError(ErrorDomain.POSIX, errno)

    # Absorbs the frozen contract's return-code sign convention, used by
    # mojito-sys C-ABI helpers:
    #   rc == 0            success (code 0,
    #   rc < 0             error, |rc| is the POSIX errno,
    #   rc > 0             positive informational value (kept as a positive
    #                      POSIX code; not itself a failure).
    @staticmethod
    def from_rc(rc: Int32) -> SysError:
        if rc < 0:
            return SysError(ErrorDomain.POSIX, -rc)
        return SysError(ErrorDomain.POSIX, rc)

    # True iff the code is 0 — which means "no failure" in every domain.
    def ok(self) -> Bool:
        return self.code == 0

    # Human-readable, diagnostic-only text. Off the hot path and NOT a stable
    # API; consumers must not parse it. POSIX errno names come from the
    # host-selected table (see `errno_name`); unknown domains and unlisted
    # codes fall back to deterministic numeric forms ("domain<N> code <N>" /
    # "POSIX errno <N>").
    def to_string(self) -> String:
        if self.domain == ErrorDomain.POSIX:
            var name = errno_name(self.code)
            if name != "":
                return "POSIX(" + name + ") errno " + String(self.code)
            return "POSIX errno " + String(self.code)
        var dname = domain_name(self.domain.value)
        if dname == "":
            dname = "domain" + String(self.domain.value)
        return dname + " code " + String(self.code)


# Raise a frozen-contract return code (mjs_* ABI convention: 0 success,
# negative errno = POSIX errno on failure) as a decoded `Error`.
#
# The body is deliberately STRAIGHT-LINE: every String piece is either a
# literal or built from the Int-packed name table with NO String-valued
# branch anywhere. b2 SIGSEGVs when a String literal reaches a raise payload
# through ANY control-flow merge (branch/loop, any module, @always_inline
# included) while lowering a raising member of a (Movable) struct in a module
# that also lowers @extern bindings — so consumers on mjs_* ABIs must raise
# through THIS function instead of hand-rolling `raise Error(err.to_string())`
# (issue #29, panel H6).
def raise_errno(rc: Int32) raises:
    var err = SysError.from_rc(rc)
    var msg = (
        "mojito-sys error: POSIX errno "
        + String(err.code)
        + " ("
        + errno_name(err.code)
        + ")"
    )
    raise Error(msg)
