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
# Raw ABI symbols (mjs_page_size / mjs_granularity) are the thin C-ABI
# bindings and are NOT for caller use: prefer page_size() and
# allocation_granularity() below. The raw names exist because b2 cannot scope
# @extern declarations lexically; keep them at arm's length in user code.
#
# Byte semantics: the address-space sizes here align with the size_t-typed
# lengths the VM/stack ABI takes (reserve/commit/decommit/protect margins are
# page-aligned). The Mojo wrappers therefore widen the narrowed C int results
# back to Int at the boundary so callers reason in Int-sized byte counts.
#
# Link with: mojo run -I <repo-root> -Xlinker <libmojito_sys.dylib> <test>


@extern("mjs_page_size")
def mjs_page_size() abi("C") -> Int32:
    ...


@extern("mjs_granularity")
def mjs_granularity() abi("C") -> Int32:
    ...


# Host page size in bytes (sysconf(_SC_PAGESIZE)); always > 0.
def page_size() -> Int:
    return Int(mjs_page_size())


# Allocation granularity for reservations in bytes; >= page size. This is the
# unit VirtualMemory uses to round reservation sizes (mmap alignment
# granularity). On POSIX it equals the page size; a distinct Windows
# granularity would be reported here when that target is added. This is
# re-exposed at the VM reservation boundary (mjs_vm_reserve) when it lands.
def allocation_granularity() -> Int:
    return Int(mjs_granularity())
