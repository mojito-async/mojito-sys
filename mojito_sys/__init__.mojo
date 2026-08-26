"""mojito_sys - system-services package for mojito (S1, issue #24).

The S1 surface is the frozen C ABI in native/include/mojito_sys.h (page, VM,
stack and ABI services), extended by the s4-time block (monotonic clock).
Landed subpackages:
  - mojito_sys.memory — page.mojo (page_conformance §6), virtual_memory.mojo
    (mmap/munmap/mprotect VM services) and stack.mojo (mjs_stack coroutines);
  - mojito_sys.time — duration.mojo + monotonic.mojo (s4/time, issue #63);
  - mojito_sys.abi — types, errors, callbacks and opaque native handles.

Package-level symbols live in the sibling modules; this module stays empty
so the `mojito_sys` import path compiles against the repo root (-I).
"""

# comptime: exports are defined in the memory/, time/ and abi/ sibling
# modules; nothing is re-exported at package level.
