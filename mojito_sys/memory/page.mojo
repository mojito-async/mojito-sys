# mojito-sys S1 — page-size / allocation-granularity query (issue #28).
#
# Exposes the frozen native page services from native/include/mojito_sys.h
# (mjs_page_size / mjs_granularity) as a clean Mojo surface. The C ABI is the
# binary-compatibility firewall; this module only adds source-level naming.
#
# Mojo 1.0.0b2 binding notes (matching spike/context_switch/mojito_spike.mojo):
#   - External symbols are declared with `@extern("<c_symbol>")` plus an
#     explicit `abi("C")` effect and a `...` body; the library is chosen at
#     link time (`mojo run -Xlinker libmojito_sys.dylib`), not in the decorator.
#   - `def` only (fn is removed on b2); C return `int` maps to Int32.
#
# Link with: mojo run -I <repo-root> -Xlinker <libmojito_sys.dylib> <test>


@extern("mjs_page_size")
def mjs_page_size() abi("C") -> Int32:
    ...


@extern("mjs_granularity")
def mjs_granularity() abi("C") -> Int32:
    ...


# Host page size in bytes (sysconf(_SC_PAGESIZE)); always > 0.
def page_size() -> Int32:
    return mjs_page_size()


# Allocation granularity for reservations in bytes; >= page size. On POSIX
# this equals the page size (mmap alignment); a distinct Windows granularity
# would be reported here when that target is added.
def allocation_granularity() -> Int32:
    return mjs_granularity()