# mojito-sys S6.5 design spike — completion-style interface sketch
# (issue #77, spec §27.2, §38.7 IOCP/io_uring rows; ADR-SYS-007, ADR-SYS-009).
#
# READINESS vs COMPLETION — the two polling models (spec §27):
#   - READINESS (epoll/kqueue): `wait(events: Span[IoEvent], timeout) -> Int`
#     reports WHEN one or more registered handles have become ready. The
#     caller then performs the I/O itself. kqueue ships first in mojito-sys
#     (S6.3, mojito_sys/io/readiness.mojo + platform/kqueue.mojo); epoll
#     follows behind the same ReadinessPoller shape (issue #76).
#   - COMPLETION (io_uring/IOCP): you SUBMIT an I/O operation up front and
#     later ACQUIRE the RESULT of that specific operation. The kernel owns
#     the I/O; the event queue carries per-operation outcomes, not "ready"
#     states. See the SubmissionToken/CompletionEntry pairing below.
#
# This file is a MOCK/SKETCH of the completion model in pure Mojo so its
# interface SHAPE can be compiled and reasoned about on this host (darwin),
# which has no io_uring. It deliberately mirrors spec §27.2 verbatim:
#
#   trait CompletionPoller:
#       def submit(...) raises -> SubmissionToken
#       def cancel(...) raises
#       def wait_completions(...) raises -> Int
#       def wake(...) raises
#
# and extends it with a NON-BLOCKING batch-acquire method, `get_events`,
# which is the completion-model analogue of a readiness non-blocking poll.
# `get_events` never parks; `wait_completions` parks only up to its timeout.
# SYS-5 (blocking is explicit) is honored: only wait_completions may block.
#
# MOCK FIDELITY (documented simplifications — this is a shape sketch only;
# real backends live in mojito_sys/io/platform/{io_uring,iocp}.mojo later):
#   * The mock "kernel" finishes EVERY submitted op immediately: submit()
#     makes one completion ready right away (delayed += 1).
#   * It models READS only, each simulating a transfer of exactly
#     MOCK_TRANSFER bytes; completions are produced strictly FIFO in
#     submission order, so the token of the j-th issued completion is j.
#   * Because submissions are consumed FIFO and tokens are 0-based issuance
#     indices, the mock needs NO per-op storage to reproduce a completion
#     entry from its token — the ring state is a handful of scalar cursors.
#     (A real ring is a circular buffer in shared/kernel memory; that is
#     exactly the sort of detail io_uring/IOCP encapsulate behind §27.2.)
#   * `cancel` validates the token range and removes one pending op; real
#     cancellation is per-token and is an open io_uring question (spec §28:
#     "cancellation semantics are tested" before io_uring ships).
#
# Allocation (SYS-4): none except the diagnostic String on the error path.
# Blocking (SYS-5): wait_completions may park its caller bounded by timeout;
# submit/cancel/get_events/wake never block. Task-aware: no — OS-thread
# granularity (the completion ring itself is task-agnostic).

from std.memory import Span

# ---- opcodes (mock subset) -------------------------------------------------
# Real io_uring has read/write/accept/connect/poll_add/... (issue #78).
comptime OP_READ = UInt32(0)
comptime OP_WRITE = UInt32(1)

# Bytes the mock "kernel" reports as transferred for any completed READ.
# Documents the shape (result == bytes_transferred like a real request) with
# a deterministic value the probe can assert. NOT a real transfer size.
comptime MOCK_TRANSFER = Int32(4096)

# ---- value types -----------------------------------------------------------

# Opaque handle to an in-flight operation; MUST be echoed exactly by the
# eventual CompletionEntry so the reactor can re-associate result -> request
# (spec §31 "preserve the opaque token accurately", completion flavour).
struct SubmissionToken(ImplicitlyCopyable):
    """Monotonic operation id handed back by submit()."""
    var seq: UInt64

    def __init__(out self, seq: UInt64):
        self.seq = seq


# One prepared operation to push into the submission queue.
struct SubmissionEntry(ImplicitlyCopyable):
    """A request to start an I/O operation (completion model)."""
    var op: UInt32
    var fd: Int32
    var offset: UInt64
    var len: UInt64

    def __init__(out self, op: UInt32, fd: Int32, offset: UInt64, len: UInt64):
        self.op = op
        self.fd = fd
        self.offset = offset
        self.len = len


# One delivered operation RESULT (the completion-model analogue of IoEvent).
struct CompletionEntry(ImplicitlyCopyable):
    """A completed operation. `token` echoes the SubmissionToken exactly;
    `result` is bytes transferred or a negative errno (like IoEvent's status,
    but for the I/O you ALREADY submitted rather than for fd readiness)."""
    var token: UInt64
    var op: UInt32
    var result: Int32
    var flags: UInt32

    def __init__(out self):
        self.token = 0
        self.op = 0
        self.result = 0
        self.flags = 0

    def __moveinit__(out self, owned existing: Self):
        self.token = existing.token
        self.op = existing.op
        self.result = existing.result
        self.flags = existing.flags

    def is_error(self) -> Bool:
        return self.result < 0


# ---- trait (spec §27.2) -----------------------------------------------

trait CompletionPoller:
    """Platform-neutral completion polling interface (spec §27.2).

    Backends: io_uring (Linux, issue #78) and IOCP (Windows) later; this
    spike validates the shape against a Mojo mock on darwin.
    """

    def submit(mut self, entry: SubmissionEntry) raises -> SubmissionToken:
        """Queue `entry` for asynchronous I/O; returns an opaque token. The
        operation proceeds in the kernel/poller and produces ONE
        CompletionEntry eventually. Never blocks."""
        ...

    def cancel(mut self, token: SubmissionToken) raises:
        """Try to abort the in-flight operation named by `token`. Cancelling
        an unknown/already-completed token is a no-op, not an error."""
        ...

    def wait_completions(
        mut self,
        completions: Span[CompletionEntry, MutAnyOrigin],
        timeout_ns: Int64,
    ) raises -> Int:
        """Fill `completions` with finished operations; returns the count
        written (0 on timeout). Blocks ONLY this OS thread, up to `timeout`
        (<=0 = non-blocking). Delivered entries are removed from the ring."""
        ...

    def get_events(
        mut self, completions: Span[CompletionEntry, MutAnyOrigin]
    ) raises -> Int:
        """NON-BLOCKING batch acquisition of already-finished operations:
        fills `completions` with everything currently ready and returns the
        count (0 when nothing is ready — never parks). Completion-model
        analogue of a readiness non-blocking poll."""
        ...

    def wake(mut self) raises:
        """Make at most ONE blocked wait_completions return promptly with
        zero completions. Never blocks. Sticks for one later wait when idle."""
        ...


# ---- mock backend ----------------------------------------------------------

struct MockCompletionRing(Movable, CompletionPoller):
    """Pure-Mojo mock of the completion model (io_uring-style ring, c.f.
    #78). Validated on its CONCRETE type in the probe (b2 cannot dispatch the
    §27.2 mut-self [Span, Int64] signature through a `[T: CompletionPoller]`
    generic — the concrete+binding-witness pattern is the readiness lane's
    precedent; the trait surface itself is unchanged).

    Scalar-cursor state only (see MOCK FIDELITY above): because completions
    are produced FIFO and token == issuance index, the mock reproduces each
    CompletionEntry from cursors alone — no submission storage needed.
    """

    var next_seq: UInt64   # token source; also == #submissions issued so far
    var delayed: UInt64    # "kernel-finished", not yet handed to the caller
    var delivered: UInt64  # completions already acquired by the caller
    var cancelled: UInt64  # ops cancelled after submit, before completion
    var wake_sticky: Bool  # one pending logical wake

    def __init__(out self):
        self.next_seq = 0
        self.delayed = 0
        self.delivered = 0
        self.cancelled = 0
        self.wake_sticky = False

    def __moveinit__(mut self, mut existing: Self):
        self.next_seq = existing.next_seq
        self.delayed = existing.delayed
        self.delivered = existing.delivered
        self.cancelled = existing.cancelled
        self.wake_sticky = existing.wake_sticky

    @staticmethod
    def create() -> MockCompletionRing:
        var r = MockCompletionRing()
        return r^

    # ---- §27.2 trait surface ----------------------------------------------

    # The mock "kernel" accepts READ/WRITE; WRITE is legal to submit but the
    # mock still simulates MOCK_TRANSFER transferred bytes (shape only).
    def submit(mut self, entry: SubmissionEntry) raises -> SubmissionToken:
        if (entry.op != OP_READ) and (entry.op != OP_WRITE):
            raise Error("MockCompletionRing.submit: unknown opcode")
        var tok = SubmissionToken(self.next_seq)
        self.next_seq += 1
        self.delayed += 1  # kernel finishes instantly in this mock
        return tok

    def cancel(mut self, token: SubmissionToken) raises:
        # Mock simplification: cancelling removes ONE still-undelivered op
        # (the oldest), not specifically `token`. Range/validity is checked;
        # real per-token cancellation is an open io_uring question (§28).
        if token.seq >= self.delivered + self.delayed:
            return  # unknown / already-delivered: no-op, not an error
        if self.delayed > 0:
            self.delayed -= 1
            self.cancelled += 1

    def wait_completions(
        mut self,
        completions: Span[CompletionEntry, MutAnyOrigin],
        timeout_ns: Int64,
    ) raises -> Int:
        # Mock: nothing ever blocks for real (no park on this host). A
        # non-positive timeout = non-blocking poll; a positive timeout would
        # park in a real backend. Wake is honored as an early zero return.
        if (self.delayed == 0) and (self.wake_sticky):
            self.wake_sticky = False
            return 0
        var n = self._drain(completions)
        return n

    def get_events(
        mut self, completions: Span[CompletionEntry, MutAnyOrigin]
    ) raises -> Int:
        if self.delayed == 0:
            return 0  # nothing ready: NEVER parks
        var n = self._drain(completions)
        return n

    def wake(mut self) raises:
        self.wake_sticky = True

    # ---- internals ---------------------------------------------------------

    def _drain(
        mut self, completions: Span[CompletionEntry, MutAnyOrigin]
    ) -> Int:
        # take = min(delayed, cap), in UInt64 to stay in one domain.
        var cap = len(completions)
        var capu = UInt64(cap)
        var take = self.delayed if (self.delayed < capu) else capu
        var i = 0
        while i < Int(take):
            var c = completions[i]
            var j = self.delivered + UInt64(i)  # issuance index of this op
            c.token = j
            c.op = OP_READ  # mock models READS only
            c.result = MOCK_TRANSFER
            c.flags = 0
            completions[i] = c
            i += 1
        self.delivered += take
        self.delayed -= take
        return Int(take)


# Deterministic completion result for a given issuance index, exposed so the
# probe can independently verify round-trip integrity without reading ring
# internals. (Visible mock contract; a real backend would not expose this.)
def mock_completion_result(token_seq: UInt64) -> Int32:
    return MOCK_TRANSFER