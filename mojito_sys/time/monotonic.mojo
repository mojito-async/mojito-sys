# mojito-sys S4.1 — MonotonicInstant + clock queries (issue #63).
#
# Spec §19 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s4-time block):
#   mjs_clock_now(uint64_t *out_ns)         — ns-normalized monotonic now;
#   mjs_clock_resolution(uint64_t *out_res) — resolution in ns.
#
# STATIC-METHOD SPELLING: the spec's `MonotonicInstant.now()` ships as a
# comptime-correct @staticmethod on the struct — b2 supports struct static
# methods repo-wide (27 sites on main; the convention is documented on
# Protection.read() in mojito_sys/memory/virtual_memory.mojo). The
# module-level `monotonic_now()` is retained as a thin documented ALIAS
# for call-site stability. `clock_resolution()` has no spec spelling at
# all (§19 only demands that calibration not repeat; the C side caches it
# behind pthread_once).
#
# Overflow contract (mirrors mojito_sys.time.duration, tested by the
# conformance suite; spec §19 requires defined overflow behavior):
# instant + Duration SATURATES at UInt64::MAX — a deadline can never wrap
# into the past; instant - Duration SATURATES AT ZERO. duration_since on
# an inverted or equal pair CLAMPS TO ZERO (same rule); unsigned underflow
# would masquerade as a gigantic future deadline.
#
# b2 conventions (matching mojito_sys/memory/virtual_memory.mojo, issue #29):
#   - @extern + abi("C") + `...`; dylib chosen at link time (-Xlinker).
#   - Out-slots are UnsafePointer[UInt64, MutAnyOrigin]: the pointer escapes
#     into an opaque callee, and MutAnyOrigin pins the post-call slot load
#     AFTER the call (an untracked origin lets -O hoist it above).
#   - Raw mjs_* externs are importable but NOT for caller use; prefer
#     monotonic_now() / clock_resolution(). The raw names exist because b2
#     cannot scope @extern declarations lexically.
#   - Raising goes through the straight-line raise_errno helper
#     (mojito_sys.abi.errors); this module adds no raise sites of its own.

from mojito_sys.abi.errors import raise_errno
from mojito_sys.time.duration import Duration, saturating_add_ns
from std.memory import stack_allocation

# Out-slot cell type for both entry points' uint64_t* parameters.
comptime NsOut = UnsafePointer[UInt64, MutAnyOrigin]


@extern("mjs_clock_now")
def mjs_clock_now(out_ns: NsOut) abi("C") -> Int32:
    ...

@extern("mjs_clock_resolution")
def mjs_clock_resolution(out_res_ns: NsOut) abi("C") -> Int32:
    ...


# Query mjs_clock_now into a scratch cell and return the reading.
def _now_ns() raises -> UInt64:
    var cell = stack_allocation[1, UInt64]()
    var rc = mjs_clock_now(cell)
    if rc != 0:
        raise_errno(rc)
    return cell[]


# Current monotonic time — thin documented alias for
# MonotonicInstant.now() (call-site stability; the spec spelling lives on
# the type).
# Never blocks (SYS-5): a single non-blocking clock read (vDSO
# clock_gettime on Linux, mach register read on macOS); raises only if
# the C ABI itself fails.
def monotonic_now() raises -> MonotonicInstant:
    return MonotonicInstant.now()


# Resolution of the monotonic clock as a Duration (>= 1 ns).
# Never blocks (SYS-5): same non-blocking clock query as monotonic_now().
def clock_resolution() raises -> Duration:
    var cell = stack_allocation[1, UInt64]()
    var rc = mjs_clock_resolution(cell)
    if rc != 0:
        raise_errno(rc)
    return Duration(cell[])


# A point on the monotonic timeline: nanoseconds since an arbitrary epoch
# (NOT wall-clock time; scheduler deadlines must live here per spec §19).
# The field is public by design (spec §19's `var ticks`) — it is the type's
# whole state and every overflowing operation is a named method below.
struct MonotonicInstant(ImplicitlyCopyable):
    var ticks: UInt64

    def __init__(out self, ticks: UInt64):
        self.ticks = ticks

    def __copyinit__(out self, existing: Self):
        self.ticks = existing.ticks

    # Time from `earlier` up to SELF. Inverted/equal pairs CLAMP TO ZERO —
    # the overflow rule of record (this module's head + spec §19), never
    # an unsigned underflow.
    def duration_since(self, earlier: Self) -> Duration:
        if self.ticks <= earlier.ticks:
            return Duration(UInt64(0))
        return Duration(self.ticks - earlier.ticks)

    # Spec §19 spelling (`MonotonicInstant.now()`): a true static method,
    # mirroring Protection.read() in mojito_sys/memory/virtual_memory.mojo.
    # Never blocks (SYS-5): single non-blocking clock read; raises only if
    # the C ABI itself fails.
    @staticmethod
    def now() raises -> MonotonicInstant:
        var ticks = _now_ns()
        return MonotonicInstant(ticks)

    # Elapsed time since this instant was taken. Raises only if the C ABI
    # itself fails (frozen -errno convention surfaces via raise_errno).
    # Never blocks (SYS-5): one non-blocking clock read + saturating math.
    def elapsed(self) raises -> Duration:
        var now = _now_ns()
        if now <= self.ticks:
            return Duration(UInt64(0))
        return Duration(now - self.ticks)

    # Saturating advance: a deadline can never wrap into the past.
    # Never blocks (SYS-5): pure saturating integer arithmetic.
    def __add__(self, rhs: Duration) -> Self:
        return MonotonicInstant(saturating_add_ns(self.ticks, rhs.ns))

    # Saturating retreat by a span: an instant can never underflow past 0
    # into gigantic ticks. Never blocks (SYS-5): pure integer arithmetic.
    def __sub__(self, rhs: Duration) -> Self:
        if self.ticks <= rhs.ns:
            return MonotonicInstant(UInt64(0))
        return MonotonicInstant(self.ticks - rhs.ns)

    def __eq__(self, other: Self) -> Bool:
        return self.ticks == other.ticks

    def __ne__(self, other: Self) -> Bool:
        return self.ticks != other.ticks

    def __lt__(self, other: Self) -> Bool:
        return self.ticks < other.ticks

    def __le__(self, other: Self) -> Bool:
        return self.ticks <= other.ticks

    def __gt__(self, other: Self) -> Bool:
        return self.ticks > other.ticks

    def __ge__(self, other: Self) -> Bool:
        return self.ticks >= other.ticks
