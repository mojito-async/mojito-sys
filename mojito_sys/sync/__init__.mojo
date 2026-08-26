"""mojito_sys.sync - native OS-thread-blocking synchronization (phase S3).

Spec §14 names these Native* deliberately: they are OS-THREAD-BLOCKING
primitives for worker sleep/wake, native coordination, and blocking-pool
infrastructure — NOT application task synchronization.

Spec surfaces bound to frozen C ABI blocks in native/include/mojito_sys.h:
  - mojito_sys.sync.common       WaitStatus shared result enum   (S3.1, #57)
  - mojito_sys.sync.mutex        NativeMutex                    (S3.1, #57)
  - mojito_sys.sync.atomic_wait  u32 wait/wake cores            (S3.3, #59)

Subpackage scaffold; wrappers live in sibling modules.
"""

# comptime: exports are defined in common.mojo / mutex.mojo.
