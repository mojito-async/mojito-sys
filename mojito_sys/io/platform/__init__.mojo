"""mojito_sys.io.platform - per-OS poller backends (S6.3, issue #75).

One module per readiness/completion backend (spec §28-§30):
  - mojito_sys.io.platform.kqueue - KqueuePoller, the ReadinessPoller
    implementation over the frozen mjs_poller_* C ABI (macOS/BSD).

All backends implement mojito_sys.io.readiness.ReadinessPoller and pass
the shared tests/s6/io/poller conformance suite.
"""

# comptime: platform exports are defined in kqueue.mojo (and later
# siblings); nothing is re-exported at package level.
