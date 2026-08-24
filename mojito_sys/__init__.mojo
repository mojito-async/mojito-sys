"""mojito_sys - system-services package for mojito (S1, issue #24).

The S1 surface is the frozen C ABI in native/include/mojito_sys.h (page, VM
and stack services). Package symbols land in later S1 lanes; this module
intentionally stays empty so the `mojito_sys` import path compiles against
the repo root (-I) for the S1 test suite.
"""

# comptime: package-level exports are added by the S1 memory/abi lanes via
# `alias` / `public` definitions in this module or sibling modules.