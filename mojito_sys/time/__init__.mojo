"""mojito_sys.time - monotonic time services for mojito (S4.1, issue #63).

Spec §19 surface bound to the frozen mjs_clock_now / mjs_clock_resolution
C ABI (native/include/mojito_sys.h, s4-time block):
  - mojito_sys.time.duration   — Duration: UInt64 nanoseconds, saturating
    arithmetic;
  - mojito_sys.time.monotonic  — MonotonicInstant + module-level
    monotonic_now() / clock_resolution().

Subpackage scaffold; the wrappers live in sibling modules.
"""

# comptime: time exports are defined in duration.mojo / monotonic.mojo.
