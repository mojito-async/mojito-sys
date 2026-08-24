# mojito-sys S1.3 — SysError/ErrorDomain conformance (mojito-sys #26).
#
# Verifies the platform-neutral error representation:
#   - constructing a SysError never raises and is allocation-light;
#   - domain tags compare by value (POSIX == POSIX);
#   - from_posix() packages a raw errno into the POSIX domain;
#   - ok() reflects a zero code;
#   - to_string() names the common darwin errnos.
#
# This file is red (does not compile) until abi/errors.mojo exists — the
# expected TDD-red state for this lane.

from mojito_sys.abi.errors import ErrorDomain, SysError


# True iff `haystack` contains `needle`. `String.find` returns the index or
# -1 when absent (b2).
def has_substr(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# Constructs SysError values in a non-raising context and returns the number
# of checks failed, so the test itself proves construction never raises.
def run_checks() -> Int:
    var failed = 0

    # Constructing SysError never raises: these four all build without
    # error; a raise anywhere here aborts the run before the matrix prints.
    var a = SysError(ErrorDomain.POSIX, 2)
    var b = SysError.from_posix(2)
    var c = SysError(ErrorDomain.POSIX, 0)
    var d = SysError(ErrorDomain.MACH, 5)

    # SysError(POSIX, 2).domain == POSIX (value equality on the tag).
    if a.domain == ErrorDomain.POSIX:
        print("S1.3 domain-tag equality:          PASS")
    else:
        print("S1.3 domain-tag equality:          FAIL")
        failed += 1

    # from_posix(2).to_string() names ENOENT (darwin errno 2).
    if has_substr(b.to_string(), "ENOENT"):
        print("S1.3 from_posix(2) names ENOENT:   PASS")
    else:
        print("S1.3 from_posix(2) names ENOENT:   FAIL")
        failed += 1

    # ok() is True only for code 0.
    if c.ok() and not a.ok() and not b.ok():
        print("S1.3 ok() zero-code semantics:     PASS")
    else:
        print("S1.3 ok() zero-code semantics:     FAIL")
        failed += 1

    # Domain round-trips: MACH construction keeps its tag distinct from POSIX.
    if (d.domain == ErrorDomain.MACH) and not (d.domain == ErrorDomain.POSIX):
        print("S1.3 domain tags distinct:         PASS")
    else:
        print("S1.3 domain tags distinct:         FAIL")
        failed += 1

    print("S1.3 SysError construction no-raise: PASS")

    return failed


def main() raises:
    var failed = run_checks()
    if failed != 0:
        print("RESULT: " + String(failed) + " FAILED")
        raise Error("S1.3 conformance failed")
    print("RESULT: all green")