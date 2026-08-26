"""mojito_sys.io - native IO services for mojito (S6.1, issue #73).

Spec §27.1 surface (readiness/completion interfaces) is anchored here:
  - mojito_sys.io.handle — NativeIoHandle, the raw descriptor/HANDLE
    value type consumed by ReadinessPoller.register(handle, ...) and by
    every other io wrapper in the §25 ownership family.

S6.2 (issue #74) adds the §26 non-blocking socket surface:
  - mojito_sys.io.externs — pure-extern leaf binding mjs_socket_*
    (b2 leaf-module workaround; NOT for caller use);
  - mojito_sys.io.socket — NativeSocket / SocketAddress / IoAttempt
    (Ready/WouldBlock/Interrupted/Error/Closed; never parks a task).

Subpackage scaffold; the wrappers live in sibling modules.
"""

# comptime: io exports are defined in handle.mojo (and later siblings).
