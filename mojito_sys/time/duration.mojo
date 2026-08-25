# mojito-sys S4.1 — Duration (issue #63).
#
# Spec §19/§1062: "time arithmetic must define overflow behavior." The
# definition here, enforced by tests/s4/time/monotonic/conformance.mojo:
#   - ADDITION saturates at UInt64::MAX (a deadline can never wrap into the
#     past — wrapping would turn an overflow into a silent correctness bug
#     in scheduler math);
#   - SUBTRACTION clamps at zero (an inverted pair means "no time left",
#     mirroring MonotonicInstant::duration_since);
#   - down-conversions (as_secs / as_millis / as_micros) TRUNCATE;
#   - factories from coarse units SATURATE rather than wrap when the
#     nanosecond product exceeds UInt64 (duration_from_secs(UInt64::MAX)
#     is a legal call and yields MAX ns).
#
# Storage is plain UInt64 nanoseconds — the same unit the C ABI normalizes
# to, so no conversion happens anywhere on this side of the boundary.
#
# Mojo 1.0.0b2 note: b2 has no struct static methods, so the coarse-unit
# constructors are MODULE-LEVEL factories (duration_from_secs /
# duration_from_millis / duration_from_micros) instead of
# @staticmethod Duration.from_secs — precedent amendment #16.


# Saturating UInt64 addition: MAX instead of wrap/trap. Shared with
# mojito_sys.time.monotonic so instant + Duration uses ONE definition.
def saturating_add_ns(a: UInt64, b: UInt64) -> UInt64:
    var cap = ~UInt64(0)
    if a > cap - b:
        return cap
    return a + b


def duration_from_secs(seconds: UInt64) -> Duration:
    # seconds * 1e9 saturates: beyond MAX/1e9 every value is MAX.
    if seconds > (~UInt64(0)) // UInt64(1000000000):
        return Duration(~UInt64(0))
    return Duration(seconds * UInt64(1000000000))


def duration_from_millis(millis: UInt64) -> Duration:
    if millis > (~UInt64(0)) // UInt64(1000000):
        return Duration(~UInt64(0))
    return Duration(millis * UInt64(1000000))


def duration_from_micros(micros: UInt64) -> Duration:
    if micros > (~UInt64(0)) // UInt64(1000):
        return Duration(~UInt64(0))
    return Duration(micros * UInt64(1000))


# A signed-less span of time: UInt64 nanoseconds, saturating arithmetic
# (see module docstring for the exact overflow contract).
struct Duration(ImplicitlyCopyable):
    # Nanoseconds. Public by design: the field IS the type's whole state
    # (mirroring spec §19's public `ticks`), and every operation that could
    # overflow is a named saturating method below.
    var ns: UInt64

    def __init__(out self, nanoseconds: UInt64):
        self.ns = nanoseconds

    def __copyinit__(out self, existing: Self):
        self.ns = existing.ns

    # --- arithmetic (total, never traps, never wraps) ----------------------

    def __add__(self, rhs: Self) -> Self:
        return Duration(saturating_add_ns(self.ns, rhs.ns))

    def __sub__(self, rhs: Self) -> Self:
        if self.ns <= rhs.ns:
            return Duration(UInt64(0))
        return Duration(self.ns - rhs.ns)

    # --- total-order comparisons -------------------------------------------

    def __eq__(self, other: Self) -> Bool:
        return self.ns == other.ns

    def __ne__(self, other: Self) -> Bool:
        return self.ns != other.ns

    def __lt__(self, other: Self) -> Bool:
        return self.ns < other.ns

    def __le__(self, other: Self) -> Bool:
        return self.ns <= other.ns

    def __gt__(self, other: Self) -> Bool:
        return self.ns > other.ns

    def __ge__(self, other: Self) -> Bool:
        return self.ns >= other.ns

    # --- conversions (TRUNCATING down-conversions; documented above) -------

    def as_secs(self) -> UInt64:
        return self.ns // UInt64(1000000000)

    def as_millis(self) -> UInt64:
        return self.ns // UInt64(1000000)

    def as_micros(self) -> UInt64:
        return self.ns // UInt64(1000)
