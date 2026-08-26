# mojito-sys S3.1 — shared WaitStatus (issue #57, spec §14 intro + §15).
#
# The result vocabulary of every TIMED native wait in spec §16-§18
# (NativeCondVar.wait_until, NativeEvent.wait_until, ...). The timed
# primitives themselves are LATER issues; this enum is the shared surface
# they will all return, landed first so the ABI slice stays coherent.
#
# SPURIOUS WAKEUP CONTRACT: implementations are PERMITTED to report
# `.ok` spuriously — a timed wait may return .ok without the awaited
# condition having become true. Every caller MUST re-check its predicate
# after any wake and loop as needed; no mojito-sys primitive will ever
# promise a condition held on return. This is the POSIX pthread_cond
# model, adopted repo-wide so wrappers never have to distinguish a
# genuine signal from a spurious one.
#
# b2 note: Mojo 1.0.0b2 has no enum sugar, so the members are comptime
# struct values (same pattern as ErrorDomain in mojito_sys/abi/errors.mojo);
# equality is by value, which also makes them safe to copy and compare.


struct WaitStatus(ImplicitlyCopyable):
    """Outcome of a timed native wait.

    Members:
      ok        — the wait returned normally. SPURIOUS WAKEUPS ARE
                  PERMITTED BY CONTRACT: the caller's predicate may still
                  be false; always re-check and re-wait in a loop.
      timed_out — the deadline expired before any wake.

    Blocking: no — pure value, never blocks (SYS-5).
    Allocation: none — one machine word (SYS-4).
    Task-aware: no — produced by OS-thread-blocking primitives (§14).
    """

    var value: Int32

    comptime ok = WaitStatus(0)
    comptime timed_out = WaitStatus(1)

    def __init__(out self, value: Int32):
        self.value = value

    # Value-type equality: two statuses are equal iff their tags match,
    # so callers can write `if st == WaitStatus.ok`.
    def __eq__(self, other: WaitStatus) -> Bool:
        return self.value == other.value

    # Mismatch must be defined whenever __eq__ is (b2 requirement).
    def __ne__(self, other: WaitStatus) -> Bool:
        return self.value != other.value
