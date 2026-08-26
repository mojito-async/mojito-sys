"""mojito_sys.io - native IO services for mojito (S6.1, issue #73).

Spec §27.1 surface (readiness/completion interfaces) is anchored here:
  - mojito_sys.io.handle — NativeIoHandle, the raw descriptor/HANDLE
    value type consumed by ReadinessPoller.register(handle, ...) and by
    every other io wrapper in the §25 ownership family.

Subpackage scaffold; the wrappers live in sibling modules.
"""

# comptime: io exports are defined in handle.mojo (and later siblings).
