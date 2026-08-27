# mojito-sys S6.5 design spike — completion interface probe
# (issue #77, spec §27.2, §38.7 IOCP/io_uring rows; ADR-SYS-009).
#
# A runnable probe of the proposed io_uring-STYLE COMPLETION interface
# SKETCH (in sibling module completion_sketch.mojo) on THIS host (darwin,
# which has no io_uring — the backend is a pure-Mojo mock ring).
#
# The probe documents the completion model's shape and contrasts it with the
# readiness model already shipped for kqueue (mojito_sys/io/readiness.mojo):
#
#   READINESS (epoll/kqueue, S6.3/#75 shipped, #76 epoll):
#       poller.register(handle, interests, token)
#       poller.wait(events: Span[IoEvent], timeout) -> Int   # fd is READY
#
#   COMPLETION (io_uring #78 / IOCP, this sketch):
#       ring.submit(SubmissionEntry) -> SubmissionToken      # start the I/O
#       ring.wait_completions(Span[CompletionEntry], t) -> Int   # it FINISHED
#       ring.get_events(Span[CompletionEntry]) -> Int  # non-blocking batch
#
# The behavioural surface proven here:
#   * submit() returns strictly-increasing, unique opaque tokens (SYS-3);
#   * completion tokens round-trip EXACTLY (the reactor can re-associate
#     result -> request; spec §31 "preserve opaque token accurately");
#   * batch acquisition: get_events/wait_completions fill at most
#     len(span) per call, so N ops need ceil(N / cap) calls;
#   * get_events is NON-BLOCKING: returns 0 immediately when idle (the
#     completion analogue of a readiness non-blocking poll), while
#     wait_completions is the blocking form (SYS-5: explicit blocking);
#   * FIFO delivery order and deterministic result integrity;
#   * wake() ends one idle wait early; cancel() removes a pending op.
#
# This is a DESIGN SPIKE: it documents interface shape and is self-checking,
# but does NOT touch native code or the packaged library (no libmojito_sys
# build; a real io_uring/IOCP backend is future work, issues #78 and later).

from std.memory import Span, stack_allocation, UnsafePointer

from completion_sketch import (
    CompletionEntry,
    CompletionPoller,
    MockCompletionRing,
    OP_READ,
    OP_WRITE,
    SubmissionEntry,
    SubmissionToken,
    MOCK_TRANSFER,
)


# One CompletionEntry occupies 24 bytes (UInt64 + three UInt32, 8-aligned)
# == 3 Int64 words. Our scratch cells are sized in Int64 words.
comptime ENTRY_WORDS = 3
comptime BUF_WORDS = 64  # 21-entry scratch buffer (512 bytes), stack-only


def check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


# Build a MutAnyOrigin completion span of `length` entries starting at byte
# offset `off_bytes` into a caller-owned Int64 scratch cell (precedent:
# tests/s6/io/poller/conformance.mojo `_fresh_span`).
def _span_at(
    cell: UnsafePointer[Int64, MutAnyOrigin],
    off_bytes: Int,
    length: Int,
) -> Span[CompletionEntry, MutAnyOrigin]:
    var p = UnsafePointer[CompletionEntry, MutAnyOrigin](
        unsafe_from_address=Int(cell) + off_bytes
    )
    return Span[CompletionEntry, MutAnyOrigin](ptr=p, length=length)


def main() raises:
    # ---- fixed-size scratch buffer for completion acquisition --------------
    var cells = stack_allocation[BUF_WORDS, Int64]()
    var off = 0  # next free byte offset within `cells`

    # ---- create the mock ring ---------------------------------------------
    var ring = MockCompletionRing.create()

    # ---- 1. submit 5 READS, collect tokens --------------------------------
    var band = stack_allocation[8, SubmissionToken]()
    var i = 0
    while i < 5:
        var op = SubmissionEntry(OP_READ, Int32(i), 0, 4096)
        band[i] = ring.submit(op)
        i += 1

    # Tokens are strictly increasing and unique (SYS-3 opaque handle).
    var j = 1
    while j < 5:
        check(band[j].seq > band[j - 1].seq, "tokens not strictly increasing")
        j += 1

    # ---- 2. non-blocking BATCH acquisition via get_events ------------------
    # Slice the scratch buffer to cap=2 entries per call; 5 ops need
    # ceil(5/2)=3 calls that drain 2, 2, 1.
    var b1 = _span_at(cells, off, 2)
    off += 2 * 24
    var n1 = ring.get_events(b1)
    check(n1 == 2, "get_events batch[1] should drain 2, got " + String(n1))
    check(b1[0].token == 0, "first completion token should be 0")
    check(b1[1].token == 1, "second completion token should be 1")
    check(b1[0].result == MOCK_TRANSFER, "completion result mismatch")

    var b2 = _span_at(cells, off, 2)
    off += 2 * 24
    var n2 = ring.get_events(b2)
    check(n2 == 2, "get_events batch[2] should drain 2, got " + String(n2))
    check(b2[0].token == 2, "FIFO: third completion token should be 2")
    check(b2[1].token == 3, "FIFO: fourth completion token should be 3")

    var b3 = _span_at(cells, off, 2)
    off += 2 * 24
    var n3 = ring.get_events(b3)
    check(n3 == 1, "get_events batch[3] should drain 1, got " + String(n3))
    check(b3[0].token == 4, "FIFO: fifth completion token should be 4")

    # ---- 3. get_events never parks: 0 when idle -----------------------------
    var idle = _span_at(cells, off, 2)
    off += 2 * 24
    var nidle = ring.get_events(idle)
    check(nidle == 0, "get_events should return 0 when nothing pending")

    # ---- 4. blocking wait_completions drains the rest -----------------------
    # Submit 3 more, acquire with one wait (cap 3).
    var k = 0
    while k < 3:
        var op = SubmissionEntry(OP_WRITE, Int32(100) + Int32(k), 0, 512)
        _ = ring.submit(op)
        k += 1
    var waitspan = _span_at(cells, off, 3)
    off += 3 * 24
    var nwait = ring.wait_completions(waitspan, 1_000_000)
    check(nwait == 3, "wait_completions should return 3, got " + String(nwait))
    check(waitspan[0].token == 5, "FIFO: wait token should be 5")

    # ---- 5. wake() ends one idle wait early ---------------------------------
    # Ring is now drained; a sticky wake makes the next idle wait return 0.
    ring.wake()
    var wakespan = _span_at(cells, off, 2)
    off += 2 * 24
    var nwake = ring.wait_completions(wakespan, 1_000_000)
    check(nwake == 0, "wake should end an idle wait with 0 completions")

    # ---- 6. cancel() removes a pending op -----------------------------------
    var opc = SubmissionEntry(OP_READ, 7, 0, 4096)
    var tokc = ring.submit(opc)
    ring.cancel(tokc)
    var cspan = _span_at(cells, off, 2)
    var nc = ring.get_events(cspan)
    check(nc == 0, "cancelled op must not produce a completion")

    # ---- print the matrix ---------------------------------------------------
    print("== s6-completion-probe")
    print("   | completion interface sketch: submit/get_events/wait_completions/cancel/wake")
    print("   | model contrast: readiness wait()  == fd is READY (kqueue now, epoll #76)")
    print("   |                 completion submit == I/O STARTED; get_events == RESULT")
    print("   | tokens strictly increasing + unique           : ok")
    print("   | completion token round-trip (31 accuracy)     : ok")
    print("   | non-blocking batch acquisition (5 = 2+2+1)    : ok")
    print("   | get_events returns 0 when idle (never parks)  : ok")
    print("   | wait_completions blocking drain               : ok")
    print("   | wake ends an idle wait early                  : ok")
    print("   | cancel removes a pending op                   : ok")
    print("RESULT: all green")