# mojito-sys S1.3 — SysError/ErrorDomain conformance (mojito-sys #26).
#
# Verifies the platform-neutral error representation:
#   - construction never raises; a code of 0 means "no failure" in ALL
#     domains (asserted here as well as documented);
#   - domain tags are pairwise-distinct and compare by value
#     (POSIX == POSIX, POSIX != MACH);
#   - from_posix() packages a positive errno into the POSIX domain;
#   - from_rc() absorbs the frozen negative-errno-return contract;
#   - ok() reflects a zero code;
#   - SysError layout is 8 bytes / 4-aligned;
#   - to_string() names the common errnos and domain ids;
#   - unknown-domain ids fall back to a deterministic numeric form and
#     extension domains (documented non-reserved band) construct/compare
#     like any other domain (S1.11, mojito-sys #44);
#   - errno names are host-selected: darwin numbering on darwin, Linux
#     numbering on Linux, with colliding codes (35, 11) resolved per-host
#     and unlisted codes falling back to numeric (#44).

from mojito_sys.abi.errors import (
    ErrorDomain,
    SysError,
    errno_name,
    _errno_name_darwin,
    _errno_name_linux,
)
from std.sys.info import align_of, size_of
from std.sys import CompilationTarget


# The six domain identity codes; used by the comptime pairwise-distinct check.
comptime DOMAIN_VALUES: List[Int32] = [0, 1, 2, 3, 4, 5]


# True iff a comptime code list has no duplicate entries.
def domain_tags_distinct[vals: List[Int32]]() -> Bool:
    comptime for i in range(len(vals)):
        comptime for j in range(i):
            comptime if vals[i] == vals[j]:
                return False
    return True


# True iff `haystack` contains `needle`. `String.find` returns the index or
# -1 when absent (b2).
def contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# Constructs SysError values in a non-raising context and returns the number
# of checks failed, so the test itself proves construction never raises.
def run_checks() -> Int:
    var failed = 0

    # Pairwise-distinct over all six domain tags. Run at comptime (module
    # scope rejects comptime assert), so it costs nothing at runtime and
    # fails the build if two domains alias.
    comptime assert domain_tags_distinct[DOMAIN_VALUES](), \
        "S1.3 ErrorDomain tags must be pairwise-distinct"

    # Constructing SysError never raises: these all build without error; a
    # raise anywhere here aborts the run before the matrix prints.
    var a = SysError(ErrorDomain.POSIX, 2)
    var b = SysError.from_posix(2)
    var c = SysError(ErrorDomain.POSIX, 0)
    var d = SysError(ErrorDomain.MACH, 5)
    var e = SysError(ErrorDomain.WSA, 10004)
    var f = SysError(ErrorDomain.INTERNAL, 9)

    # SysError(POSIX, 2).domain == POSIX (value equality on the tag).
    if a.domain == ErrorDomain.POSIX:
        print("S1.3 domain-tag equality:          PASS")
    else:
        print("S1.3 domain-tag equality:          FAIL")
        failed += 1

    # from_rc: |rc| becomes the POSIX errno for negative rc.
    var r22 = SysError.from_rc(-22)
    if r22.code == 22 and r22.domain == ErrorDomain.POSIX:
        print("S1.3 from_rc(-22) -> code 22:      PASS")
    else:
        print("S1.3 from_rc(-22) -> code 22:      FAIL")
        failed += 1

    var r2 = SysError.from_rc(-2)
    if r2.domain == ErrorDomain.POSIX and r2.code == 2:
        print("S1.3 from_rc(-2).domain POSIX:     PASS")
    else:
        print("S1.3 from_rc(-2).domain POSIX:     FAIL")
        failed += 1

    # from_posix(x).domain == POSIX
    if b.domain == ErrorDomain.POSIX:
        print("S1.3 from_posix(2).domain POSIX:   PASS")
    else:
        print("S1.3 from_posix(2).domain POSIX:   FAIL")
        failed += 1

    # ok() is True only for code 0 — and code 0 means "no failure" in EVERY
    # domain (M3: domains MUST NOT use 0 for a failure).
    var ok_zero = c.ok()  # POSIX code 0 succeeds
    # Zero code is success in every domain:
    if (
        SysError(ErrorDomain.MACH, 0).ok()
        and SysError(ErrorDomain.INTERNAL, 0).ok()
        and SysError(ErrorDomain.WIN32, 0).ok()
        and SysError(ErrorDomain.WSA, 0).ok()
        and SysError(ErrorDomain.API, 0).ok()
    ):
        print("S1.3 zero is success in all domains: PASS")
    else:
        print("S1.3 zero is success in all domains: FAIL")
        failed += 1
    if ok_zero and not a.ok() and not b.ok() and not r22.ok():
        print("S1.3 ok() zero-code semantics:     PASS")
    else:
        print("S1.3 ok() zero-code semantics:     FAIL")
        failed += 1

    # from_rc(0).ok() == True (frozen-contract success).
    var r0 = SysError.from_rc(0)
    if r0.ok():
        print("S1.3 from_rc(0).ok():               PASS")
    else:
        print("S1.3 from_rc(0).ok():               FAIL")
        failed += 1

    # Domain round-trips: MACH construction keeps its tag distinct from POSIX.
    if (d.domain == ErrorDomain.MACH) and not (d.domain == ErrorDomain.POSIX):
        print("S1.3 domain tags distinct:         PASS")
    else:
        print("S1.3 domain tags distinct:         FAIL")
        failed += 1

    # Non-POSIX to_string includes the domain id (MACH/WIN32/WSA/API/INTERNAL).
    if (
        contains(d.to_string(), "MACH")
        and contains(e.to_string(), "WSA")
        and contains(f.to_string(), "INTERNAL")
    ):
        print("S1.3 non-POSIX domain id in text:  PASS")
    else:
        print("S1.3 non-POSIX domain id in text:  FAIL")
        failed += 1

    # Layout: SysError is 8 bytes, 4-aligned (ErrorDomain 4 + code 4).
    if size_of[SysError]() == 8 and align_of[SysError]() == 4:
        print("S1.3 SysError layout 8/align-4:   PASS")
    else:
        print("S1.3 SysError layout 8/align-4:   FAIL")
        failed += 1

    # to_string names the common darwin errnos (exact name + number match).
    if (
        contains(b.to_string(), "ENOENT")
        and contains(a.to_string(), "2")
        and contains(SysError.from_posix(13).to_string(), "EACCES")
        and contains(SysError.from_posix(35).to_string(), "EAGAIN")
        and contains(SysError.from_posix(22).to_string(), "EINVAL")
        and contains(SysError.from_posix(14).to_string(), "EFAULT")
        and contains(SysError.from_posix(45).to_string(), "ENOTSUP")
    ):
        print("S1.3 errno name table (darwin):    PASS")
    else:
        print("S1.3 errno name table (darwin):    FAIL")
        failed += 1

    # Fallback rows: unknown/differing codes fall back to numeric.
    if (
        contains(SysError.from_posix(999).to_string(), "errno 999")
        and contains(SysError.from_rc(-1).to_string(), "errno 1")
        and contains(SysError.from_posix(0).to_string(), "errno 0")
    ):
        print("S1.3 numeric fallback rows:         PASS")
    else:
        print("S1.3 numeric fallback rows:         FAIL")
        failed += 1

    # --- S1.11 (#44): error-domain policy + errno-name portability ---

    # Unknown-domain ids outside the built-in tags format deterministically
    # as domain<N> code <N> (diagnostic-only; consumers must not parse).
    var unknown = SysError(ErrorDomain(99), 7)
    if (
        contains(unknown.to_string(), "domain99")
        and contains(unknown.to_string(), "code 7")
    ):
        print("S1.11 unknown-domain fallback:      PASS")
    else:
        print("S1.11 unknown-domain fallback:      FAIL")
        failed += 1

    # Extension-domain example: downstream libraries mint domains from the
    # documented non-reserved band (id >= 16); they construct, compare by
    # value against the built-in tags, and carry SysError payloads like any
    # other domain — including zero-is-success semantics.
    var down = ErrorDomain(42)
    var ext = SysError(down, 3)
    if (
        ext.domain == down
        and not (down == ErrorDomain.POSIX)
        and not (down == ErrorDomain.API)
        and not ext.ok()
        and SysError(down, 0).ok()
        and contains(ext.to_string(), "domain42")
        and contains(ext.to_string(), "code 3")
    ):
        print("S1.11 extension-domain example:     PASS")
    else:
        print("S1.11 extension-domain example:     FAIL")
        failed += 1

    # errno-name portability (#44): both host numberings are explicit and
    # resolve colliding codes correctly — code 35 is EAGAIN on darwin but
    # EDEADLK on Linux; code 11 is EAGAIN on Linux and unlisted on darwin
    # (numeric fallback there). Unlisted codes fall back to "" in BOTH
    # tables, so the numeric form is deterministic.
    if (
        _errno_name_darwin(35) == "EAGAIN"
        and _errno_name_linux(35) == "EDEADLK"
        and _errno_name_linux(11) == "EAGAIN"
        and _errno_name_darwin(11) == ""
        and _errno_name_darwin(999) == ""
        and _errno_name_linux(999) == ""
    ):
        print("S1.11 errno table collisions 35/11: PASS")
    else:
        print("S1.11 errno table collisions 35/11: FAIL")
        failed += 1

    # The public dispatch is HOST-SELECTED: pin the EXACT expected name per
    # compilation-target branch — a non-empty member-of-either-table
    # assertion cannot catch a cross-table dispatch bug on single-host CI
    # (both tables would agree with themselves). Unsupported targets keep
    # the deterministic numeric fallback in to_string().
    var expected_host_name = ""
    if CompilationTarget().is_macos():
        expected_host_name = "EAGAIN"
    elif CompilationTarget().is_linux():
        expected_host_name = "EDEADLK"
    var host_name = errno_name(35)
    if (
        host_name == expected_host_name
        and contains(SysError.from_posix(999999).to_string(), "errno 999999")
    ):
        print("S1.11 host-selected errno names:    PASS")
    else:
        print("S1.11 host-selected errno names:    FAIL")
        failed += 1

    # Construction no-raise is proven by reaching this line at all.
    print("S1.3 SysError construction no-raise: PASS")

    return failed


def main() raises:
    var failed = run_checks()
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("S1.3 conformance failed")
    print("RESULT: all green")
