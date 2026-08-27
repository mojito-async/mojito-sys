# mojito-sys S6.3 — ReadinessPoller trait (issue #75, spec §27.1).
#
# The §27.1 readiness interface, verbatim in shape:
#
#   trait ReadinessPoller:
#       def register(mut self, handle: NativeIoHandle, interests, token) raises
#       def modify(mut self, ...) raises
#       def unregister(mut self, ...) raises
#       def wait(mut self, events: Span[IoEvent], timeout: Optional[Duration])
#           raises -> Int
#       def wake(mut self) raises
#
# DOCUMENTED b2 ADAPTATIONS (mirroring the s6-socket lane's precedent):
#   - GENERIC DISPATCH LIMITATION (b2 1.0.0b2, reproduced minimized in this
#     lane): invoking `wait` through a `[T: ReadinessPoller]`-constrained
#     generic SIGSEGVs the compiler during lowering (the
#     (Span, Optional[Duration]) mut-self signature is the trigger;
#     register/modify/unregister dispatch fine). Backends are therefore
#     validated against their CONCRETE type plus a compile-time trait-
#     binding witness (`_trait_witness[T: ReadinessPoller]` in the shared
#     conformance suite) until a toolchain fix lands. The trait surface
#     itself is unchanged.
#   - `interests` ships as the typed IoInterest value carrier
#     (mojito_sys.io.poller.IoInterest); semantics identical to the spec's
#     bare parameter name.
#   - `wait` returns Int = the number of IoEvent entries FILLED (0..len);
#     timeout expiry is success-with-zero. Transient -EINTR RAISES a decoded
#     POSIX error (callers retry by catching; §38.11 interrupt/retry lives
#     one layer up in the reactor). Every other C failure also raises.
#   - timeout: Optional[Duration] where None = block indefinitely,
#     Some(0) = non-blocking poll.
#
# CONTRACTS every backend MUST honor (spec §31):
#   - tokens are preserved ACCURATELY through delivery (opaque upstream
#     identity; generation checking belongs to mojito-async);
#   - register/modify/unregister/wake NEVER block (SYS-5); only wait may
#     park its calling OS thread, bounded by its timeout;
#   - registered descriptors are BORROWED: a poller never closes them.

from std.memory import Span

from mojito_sys.io.handle import NativeIoHandle
from mojito_sys.io.poller import IoEvent, IoInterest
from mojito_sys.time.duration import Duration


trait ReadinessPoller:
    """Platform-neutral readiness polling interface (spec §27.1).

    Backends: kqueue (mojito_sys.io.platform.kqueue.KqueuePoller) today;
    epoll/IOCP/io_uring land behind the same shape per spec §28–§30.
    """

    def register(
        mut self, handle: NativeIoHandle, interests: IoInterest, token: UInt64
    ) raises:
        """Start watching `handle` for `interests`; deliveries carry
        `token` EXACTLY. Re-registration is an upsert (last wins)."""
        ...

    def modify(
        mut self, handle: NativeIoHandle, interests: IoInterest, token: UInt64
    ) raises:
        """Change interests/token of an existing registration."""
        ...

    def unregister(mut self, handle: NativeIoHandle) raises:
        """Stop watching `handle`; never closes it. Unregistered or
        already-closed handles degrade to no-ops, not errors."""
        ...

    def wait(
        mut self,
        events: Span[IoEvent, MutAnyOrigin],
        timeout: Optional[Duration],
    ) raises -> Int:
        """Fill `events` with ready registrations; returns the count
        written (0 on timeout/wake). Blocks ONLY this OS thread and only
        up to `timeout` (None = indefinitely)."""
        ...

    def wake(mut self) raises:
        """Make at most ONE blocked wait return promptly with zero
        events. Never blocks; sticks for one later wait when idle."""
        ...
