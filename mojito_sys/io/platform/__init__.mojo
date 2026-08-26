"""mojito_sys.io.platform - per-OS poller backends (S6.3, issue #75).

One module per readiness/completion backend (spec §27-§30):
  - mojito_sys.io.platform.kqueue - KqueuePoller, the ReadinessPoller
    implementation over the frozen mjs_poller_* C ABI (macOS/BSD, S6.3).
  - mojito_sys.io.platform.epoll  - EpollPoller, the ReadinessPoller
    implementation over the frozen mjs_epoll_* C ABI (Linux, S6.4).

ALL backends implement mojito_sys.io.readiness.ReadinessPoller and (on
their host) pass the shared tests/s6/io/poller (kqueue) / the Linux CI
tests/s6/io/epoll (epoll) conformance suites.

SELECTION (caller-driven; nothing is auto-selected here):
  epoll is LINUX-ONLY — on a non-Linux host EpollPoller.create() raises
  an explicit unsupported-platform error. kqueue is macOS/BSD-only. A
  reactor picks the poller matching CompilationTarget (Linux ->
  EpollPoller, macOS/BSD -> KqueuePoller, Windows (future) -> IOCP).
"""

# comptime: platform exports are defined in kqueue.mojo / epoll.mojo;
# nothing is re-exported at package level.