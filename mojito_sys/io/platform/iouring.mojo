# mojito-sys S6.6 — IoUringPoller experimental backend (issue #78, spec §28/
# §30/§27.2/§31 + §38.7 io_uring-specific rows).
#
# ReadinessPoller implementation over the frozen mjs_iouring_* C ABI
# (native/include/mojito_sys.h, s6-ioring block; native/posix/mjs_iouring.c).
#
# CAPABILITY FLAG (spec §28: "io_uring MUST remain behind a capability/
# feature flag until operation coverage, cancellation semantics, kernel-
# version behavior and benchmarks are understood"): this backend is usable
# ONLY when the host kernel supports io_uring AND the explicit environment
# flag MOJITO_IO_URING=1 is set. IoUringPoller.create() raises a decoded
# error (-ENOSYS) when the flag is missing OR the host has no io_uring —
# see ADR-SYS-007 (readiness and completion variants may coexist) and the
# §30 Linux backend note.
#
# SELECTION: this module is reachable at its EXPLICIT module path
# mojito_sys.io.platform.iouring — it is NOT the selected Linux default
# (the platform pick lives with the epoll lane in
# mojito_sys.io.platform.__init__ and is out of scope here). Consumers opt
# in by importing this module directly and honoring the capability flag.
#
# DOCUMENTED b2 ADAPTATIONS (mirroring the s6-poller kqueue lane):
#   - def-only members; construction via @staticmethod create() + _adopt(),
#     because the extern-reaching path must stay non-raising until each rc
#     is decoded;
#   - wait() shape: carve scratch OUTSIDE, ONE straight-line probe call,
#     decode strictly AFTER the call returns. Delivery is a single memcpy
#     of the raw results — the shared mjs_poll_event layout (token@0, fd@8,
#     events@12) is bit-identical to IoEvent {UInt64, Int32, UInt32} and C
#     writes only the four defined flag bits;
#   - interests cross the FFI as Int32 (bit-preserving; UInt32 scalars are
#     byval-poisoned in b2);
#   - the Optional[Duration] branch is confined to _timeout_slot, a helper
#     with no extern call (atomic_wait precedent).
#
# EINTR doctrine (§38.11): wait surfaces raw -EINTR as a DECODED raise
# (callers catch-and-retry one layer up); every other failure raises too.
# timeout expiry is success-with-zero events. Wake deliveries never occupy
# event slots but DO end a wait early.
#
# Blocking (SYS-5): ONLY wait() parks its OS thread (bounded by its
# timeout); register/modify/unregister/wake/close/entries never block.
# Allocation (SYS-4): comptime-sized stack scratch per call; the ring is
# owned by the C handle. Task-aware: no — OS-thread granularity per §14.

from std.memory import Span, UnsafePointer, stack_allocation, memcpy

import mojito_sys.io.externs as _externs
from mojito_sys.abi.errors import raise_errno
from mojito_sys.io.handle import NativeIoHandle
from mojito_sys.io.poller import IoEvent, IoInterest
from mojito_sys.io.readiness import ReadinessPoller
from mojito_sys.time.duration import Duration

# Deterministic consumed/misuse codes (frozen ABI: -errno). EINVAL spells
# 22 on darwin AND Linux; EINTR is 4 on both; ENOSYS is 45 darwin / 38
# Linux (capability-gate raise).
comptime EINVAL_RC = Int32(-22)
comptime EINTR_RC = Int32(-4)
comptime ENOSYS_RC = Int32(-38)

# One wait's C-side batch ceiling (contract: beyond-cap deliveries are
# dropped; callers loop). COMPTIME-sized so the wait path allocates only
# stack scratch.
comptime MAX_BATCH = 256

# Wait-status classification of the raw C rc (mapping core made visible
# for §38.7 interrupt/retry conformance; mirrors the kqueue lane).
comptime WAIT_OK = UInt8(0)
comptime WAIT_INTERRUPTED = UInt8(1)
comptime WAIT_ERROR = UInt8(2)


def classify_wait_rc(rc: Int32) -> UInt8:
    """Classify a raw mjs_iouring_wait rc: OK (count valid), INTERRUPTED
    (-EINTR: caller retries), or ERROR. Pure function; never blocks."""
    if rc == 0:
        return WAIT_OK
    if rc == EINTR_RC:
        return WAIT_INTERRUPTED
    return WAIT_ERROR


def _decode_rc(rc: Int32) raises:
    # Straight-line raise through the shared helper (H6 doctrine): no
    # String-valued branches anywhere on the path to `raise`.
    if rc != 0:
        raise_errno(rc)


def _buf_of(cell: UnsafePointer[Int64, MutAnyOrigin]) -> UnsafePointer[Byte, MutAnyOrigin]:
    return UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=Int(cell))


def _timeout_slot(
    timeout: Optional[Duration],
    cell: UnsafePointer[UInt64, MutAnyOrigin],
) -> _externs.TimeoutSlot:
    # The Optional branch lives HERE, in a helper with no extern call
    # (atomic_wait precedent). NULL slot = infinite wait.
    var zero = 0
    var slot = _externs.TimeoutSlot(unsafe_from_address=zero)
    var dl = timeout
    if dl:
        cell[] = dl.take().ns
        slot = cell
    return slot


struct IoUringPoller(Movable, ReadinessPoller):
    """ReadinessPoller over io_uring (spec §30), EXPERIMENTAL (spec §28).

    Capability-gated: construction requires host io_uring support AND the
    MOJITO_IO_URING=1 flag; otherwise create() raises. The poller is
    NON-OWNING of descriptors: registered fds are borrowed (spec §25);
    close() consumes the ring, never the fds. Tokens ride through poll
    user_data verbatim (§31 MUST preserve accurately).

    Blocking (SYS-5): wait() parks its caller bounded by the timeout; every
    other member never blocks. Allocation (SYS-4): stack scratch per call.
    Task-aware: no.
    """

    var ptr: _externs.UringPtr
    var closed: Bool

    def __init__(out self):
        var zero = 0
        self.ptr = _externs.UringPtr(unsafe_from_address=zero)
        self.closed = True

    def __moveinit__(mut self, mut existing: Self):
        self.ptr = existing.ptr
        self.closed = existing.closed

    @staticmethod
    def create() raises -> IoUringPoller:
        """Create an io_uring-backed poller.

        CAPABILITY GATE (spec §28): raises a decoded -ENOSYS error when the
        host kernel lacks io_uring OR the explicit MOJITO_IO_URING=1 flag is
        not set — the backend is deliberately unavailable without both.
        """
        var slot = stack_allocation[1, _externs.UringPtr]()
        var rc = _externs.probe_uring_create(slot)
        _decode_rc(rc)
        return IoUringPoller._adopt(slot[0])

    @staticmethod
    def _adopt(handle: _externs.UringPtr) -> IoUringPoller:
        var p = IoUringPoller()
        p.ptr = handle
        p.closed = False
        return p^

    # The raw opaque C handle (fixture/test plumbing).
    def handle_ptr(self) -> _externs.UringPtr:
        return self.ptr

    def is_closed(self) -> Bool:
        return self.closed

    # ---- §27.1 trait surface ------------------------------------------------

    def register(
        mut self, handle: NativeIoHandle, interests: IoInterest, token: UInt64
    ) raises:
        """Start watching `handle`; deliveries carry `token` EXACTLY.
        Re-registration is an upsert (last interests+token win)."""
        if self.closed:
            raise_errno(EINVAL_RC)
        var rc = _externs.probe_uring_register(
            self.ptr, handle.get(), Int32(interests.bits), token
        )
        _decode_rc(rc)

    def modify(
        mut self, handle: NativeIoHandle, interests: IoInterest, token: UInt64
    ) raises:
        """Change interests/token of an existing registration."""
        if self.closed:
            raise_errno(EINVAL_RC)
        var rc = _externs.probe_uring_modify(
            self.ptr, handle.get(), Int32(interests.bits), token
        )
        _decode_rc(rc)

    def unregister(mut self, handle: NativeIoHandle) raises:
        """Stop watching `handle`; NEVER closes it. Not-registered
        descriptors degrade to success (no-op), per the frozen header."""
        if self.closed:
            raise_errno(EINVAL_RC)
        var rc = _externs.probe_uring_unregister(self.ptr, handle.get())
        _decode_rc(rc)

    def wake(mut self) raises:
        """Make at most ONE blocked wait return promptly with zero
        events; sticks for one later wait when idle. Never blocks."""
        if self.closed:
            raise_errno(EINVAL_RC)
        var rc = _externs.probe_uring_wake(self.ptr)
        _decode_rc(rc)

    def close(mut self) raises:
        """Consume the poller handle; double close raises -EINVAL.
        Registered descriptors are NOT closed (non-owning, §25)."""
        if self.closed:
            raise_errno(EINVAL_RC)
        var slot = stack_allocation[1, _externs.UringPtr]()
        slot[0] = self.ptr
        var rc = _externs.probe_uring_close(slot)
        _decode_rc(rc)
        var zero = 0
        self.ptr = _externs.UringPtr(unsafe_from_address=zero)
        self.closed = True

    def wait(
        mut self,
        events: Span[IoEvent, MutAnyOrigin],
        timeout: Optional[Duration],
    ) raises -> Int:
        """Fill `events` with ready registrations; return how many.

        Blocks THIS OS THREAD only, up to `timeout` (None = until an
        event or wake; Some(0) = non-blocking poll). Timeout expiry is
        SUCCESS with zero. Raw -EINTR raises decoded (caller retries,
        §38.11); any other C failure raises too.
        """
        var n = len(events)
        if n == 0:
            raise_errno(EINVAL_RC)
        var cap = n if (n < MAX_BATCH) else MAX_BATCH
        var ncell = stack_allocation[1, UInt32]()
        var dl_cell = stack_allocation[1, UInt64]()
        var tslot = _timeout_slot(timeout, dl_cell)
        var buf = stack_allocation[MAX_BATCH * 2, Int64]()
        var bp = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=Int(buf))
        var rc = _externs.probe_uring_wait(
            self.ptr, bp, Int32(cap), tslot, ncell
        )
        if rc != 0:
            raise_errno(rc)
        var count = Int(ncell[])
        if count > 0:
            # Bit-identical layouts: deliver with ONE memcpy (scalar-loop
            # decode shares a frame with the probe and SIGSEGVs b2).
            var dst = UnsafePointer[IoEvent, MutAnyOrigin](
                unsafe_from_address=Int(events.unsafe_ptr())
            )
            var srcp = UnsafePointer[IoEvent, MutAnyOrigin](
                unsafe_from_address=Int(buf)
            )
            memcpy(dest=dst, src=srcp, count=count)
        return count

    # ---- §38.7 io_uring-specific: SQ/CQ geometry ----------------------------

    def entries(
        mut self, out_sq: _externs.U32Slot, out_cq: _externs.U32Slot
    ) -> Int32:
        """Query the configured SQ and CQ entry counts (non-blocking).
        Returns the raw C rc (0 on success)."""
        if self.closed:
            return EINVAL_RC
        return _externs.probe_uring_entries(self.ptr, out_sq, out_cq)