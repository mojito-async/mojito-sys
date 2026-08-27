"""mojito_sys.io - native IO services for mojito (S6, issues #73-#75).

Spec §26/§27 surface anchored here:
  - mojito_sys.io.handle - NativeIoHandle / OwnedFd / BorrowedFd: the raw
    descriptor value family consumed by ReadinessPoller.register() and
    every other io wrapper in the §25 ownership family (S6.1);
  - mojito_sys.io.socket - NativeSocket / SocketAddress / IoAttempt:
    non-blocking sockets (S6.2);
  - mojito_sys.io.poller - IoInterest / IoEvent: shared readiness value
    plumbing crossing the trait boundary (S6.3);
  - mojito_sys.io.readiness - the ReadinessPoller trait (§27.1) (S6.3);
  - mojito_sys.io.platform.kqueue - KqueuePoller, the macOS/BSD kqueue
    backend implementing ReadinessPoller over mjs_poller_* (S6.3).
"""

# comptime: io exports are defined in handle.mojo and its later siblings;
# nothing is re-exported at package level.
