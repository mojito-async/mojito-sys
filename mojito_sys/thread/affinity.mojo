# mojito-sys S2.6 — CpuSet builder + current-thread affinity (issue #53,
# spec §13).
#
# Bound to the frozen s2-cpu ABI entry point mjs_cpu_affinity_set_current
# (native/include/mojito_sys.h): pins the CALLING THREAD ONLY. bit i of
# word w selects logical CPU w*64 + i; mask == NULL or nwords == 0 is
# -EINVAL. Linux: sched_setaffinity — an exact pin within the process's
# own cpuset. Darwin: thread_policy_set best-effort — hosts without thread
# affinity support return exactly -ENOTSUP, and where the call SUCCEEDS the
# mask contents are ignored (coarse prefer-current-core hint, not an exact
# pin). SYS-7 divergence made VISIBLE: darwin callers must accept success
# OR a SysError carrying ENOTSUP.
#
# SCOPE NOTE (issue #53): spawn-time affinity (pinning a NEW thread at
# creation) is deliberately deferred as an extend-only follow-up; the
# standalone current-thread API satisfies the §41 deliverable (L2329).
#
# DESIGN NOTES:
#   - CpuSet is a fixed-capacity, allocation-free value type: 8 words of
#     InlineArray = 512 addressable logical CPUs, with a `nwords` high-water
#     mark so small sets never pay for the full width. Builders RAISE
#     EINVAL on ranges beyond capacity rather than truncating silently.
#   - Empty set -> set_current_thread_affinity raises EINVAL BEFORE crossing
#     the ABI (frozen contract: nwords == 0 is -EINVAL; enforcing it in
#     Mojo keeps the raise site straight-line and the ABI call total).
#   - Errno detection on raised errors matches decoded NAMES ("ENOTSUP" /
#     "EINVAL") via the mojito_sys.abi.errors Int-packed table, not raw
#     numbers.
#
# b2 conventions (matching mojito_sys/time/monotonic.mojo):
#   - Out-slots/escaping pointers use MutAnyOrigin (pins post-call loads).
#   - Raw mjs_* externs are importable but NOT for caller use.

from mojito_sys.abi.errors import raise_errno
from std.memory import UnsafePointer, stack_allocation

comptime MaskPtr = UnsafePointer[UInt64, MutAnyOrigin]

# Capacity: 8 mask words = CPUs 0..511. A fixed InlineArray keeps CpuSet a
# flat, allocation-free value type; the builders guard the bound explicitly.
comptime CPUSET_WORDS = 8

# darwin AND Linux agree: EINVAL = 22. Carried as an rc so validation
# failures share the ABI path's single raise_errno site.
comptime _EINVAL_RC = Int32(-22)


@extern("mjs_cpu_affinity_set_current")
def mjs_cpu_affinity_set_current(mask: MaskPtr, nwords: UInt32) abi("C") -> Int32:
    ...


# An immutable set of logical CPUs, built by from_range / from_mask.
# Value type: copyable, no heap, no teardown. `words[w]` bit i selects
# CPU w*64 + i (frozen ABI layout); `nwords` is the number of words in use.
struct CpuSet(ImplicitlyCopyable):
    var words: InlineArray[UInt64, CPUSET_WORDS]
    var nwords: Int

    def __init__(out self):
        self.words = InlineArray[UInt64, CPUSET_WORDS](fill=0)
        self.nwords = 0

    def __copyinit__(out self, existing: Self):
        self.words = InlineArray[UInt64, CPUSET_WORDS](fill=0)
        self.nwords = existing.nwords
        var w = 0
        while w < self.nwords:
            self.words[w] = existing.words[w]
            w += 1

    # Set covering CPUs start..end-1 (end exclusive). Raises EINVAL when
    # end < start or the range exceeds CPUSET_WORDS*64 bits — rejection,
    # never silent truncation. An empty range (start == end) is ACCEPTED
    # here and rejected at pin time (see set_current_thread_affinity), so
    # computed sets fail at the point of use, not construction.
    # Blocking: no. Allocates: no. Thread-safe: yes. Reentrant: yes.
    # Signal-safe: no guarantee. Ownership: value semantics.
    # Platform notes: none. Stability: experimental.
    @staticmethod
    def from_range(start: Int, end: Int) raises -> CpuSet:
        if end < start or end > CPUSET_WORDS * 64:
            raise_errno(_EINVAL_RC)
        var cs = CpuSet()
        if end == start:
            return cs
        cs.nwords = (end - 1) // 64 + 1
        var cpu = start
        while cpu < end:
            cs.words[cpu // 64] |= UInt64(1) << UInt64(cpu % 64)
            cpu += 1
        return cs

    # Set from explicit mask words, low word first: from_mask(w0) covers
    # CPUs 0..63, from_mask(w0, w1) covers 0..127, ... Raises EINVAL past
    # CPUSET_WORDS words.
    # Blocking: no. Allocates: no. Thread-safe: yes. Reentrant: yes.
    # Signal-safe: no guarantee. Ownership: value semantics.
    # Platform notes: none. Stability: experimental.
    @staticmethod
    def from_mask(first: UInt64, *rest: UInt64) raises -> CpuSet:
        if 1 + len(rest) > CPUSET_WORDS:
            raise_errno(_EINVAL_RC)
        var cs = CpuSet()
        cs.words[0] = first
        cs.nwords = 1
        for r in rest:
            cs.words[cs.nwords] = r
            cs.nwords += 1
        return cs

    # True iff `cpu` is selected. Negative or out-of-capacity indices are
    # simply not members.
    # Blocking: no. Allocates: no. Thread-safe: yes. Reentrant: yes.
    # Signal-safe: no guarantee. Ownership: value semantics.
    # Platform notes: none. Stability: experimental.
    def contains(self, cpu: Int) -> Bool:
        if cpu < 0 or cpu >= CPUSET_WORDS * 64:
            return False
        var w = cpu // 64
        if w >= self.nwords:
            return False
        return (self.words[w] >> UInt64(cpu % 64)) & UInt64(1) != UInt64(0)

    # True iff no CPU is selected (empty sets are refused at pin time).
    # Blocking: no. Allocates: no. Thread-safe: yes. Reentrant: yes.
    # Signal-safe: no guarantee. Ownership: value semantics.
    # Platform notes: none. Stability: experimental.
    def is_empty(self) -> Bool:
        var w = 0
        while w < self.nwords:
            if self.words[w] != UInt64(0):
                return False
            w += 1
        return True


# Pin the CALLING THREAD to the CPUs selected by `set` (spec L914-921).
# Linux pins exactly (within the process cpuset); darwin is best-effort and
# may report ENOTSUP — callers on darwin MUST treat "success or SysError
# ENOTSUP" as the accepted outcome (SYS-7 visible divergence). An empty set
# raises EINVAL before crossing the ABI (frozen contract: nwords == 0 is
# -EINVAL). Success does NOT promise the exact set was applied on darwin.
# Blocking: no (scheduler call; it does not wait for a migration).
# Allocates: one stack buffer for the mask (no heap traffic).
# Thread-safe: yes (affects only the calling thread).
# Reentrant: yes.
# Signal-safe: no guarantee.
# Ownership: borrows `set` for the duration of the call; retains nothing.
# Platform notes: Linux sched_setaffinity(0, ...) on the calling thread;
#   darwin thread_policy_set (mask contents advisory there). Spawn-time
#   affinity deliberately deferred (extend-only follow-up, issue #53).
# Stability: experimental.
def set_current_thread_affinity(set: CpuSet) raises:
    if set.is_empty():
        raise_errno(_EINVAL_RC)
    var cell = stack_allocation[CPUSET_WORDS, UInt64]()
    var w = 0
    while w < set.nwords:
        cell[w] = set.words[w]
        w += 1
    var rc = mjs_cpu_affinity_set_current(cell, UInt32(set.nwords))
    if rc != 0:
        raise_errno(rc)
