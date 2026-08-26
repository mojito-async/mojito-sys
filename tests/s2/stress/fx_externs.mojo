# mojito-sys S2.8 — test-local FFI leaf (issue #55, SYS-D6).
#
# LEAF MODULE (b2 doctrine, mirrors mojito_sys/thread/externs.mojo): ONLY
# @extern declarations and the pointer aliases they need — no imports, no
# structs, no raise sites. b2 1.0.0b2's cross-module lowering misbinds
# extern register arguments when the declaring module also hosts Movable
# types / raising machinery (#49), so the stress driver keeps every raw
# binding at arm's length here.
#
# Two symbol families:
#   - mjs_fx_* : the sharded-ledger atomics compiled from atomic_shim.c in
#     this directory (TEST-LOCAL — not part of libmojito_sys; the frozen
#     ABI gains no new symbols).
#   - libc glue: getenv (SOAK flag), exit (nonzero FAIL exit from main),
#     sched_yield (barrier spin courtesy).
#
# NEVER-INLINE INVARIANT: these stay tiny, non-raising, aggregate-free.

comptime WordPtr = UnsafePointer[Int64, MutAnyOrigin]
comptime ByteMutPtr = UnsafePointer[Byte, MutAnyOrigin]


@extern("mjs_fx_fetch_add")
def fx_add(p: WordPtr, v: Int64) abi("C") -> Int64:
    ...


@extern("mjs_fx_load")
def fx_load(p: WordPtr) abi("C") -> Int64:
    ...


@extern("mjs_fx_store")
def fx_store(p: WordPtr, v: Int64) abi("C"):
    ...


@extern("getenv")
def c_getenv(name: ByteMutPtr) abi("C") -> ByteMutPtr:
    ...


@extern("exit")
def c_exit(code: Int32) abi("C"):
    ...


@extern("sched_yield")
def c_sched_yield() abi("C") -> Int32:
    ...


@extern("clock_gettime")
def c_clock_gettime(clk_id: Int32, tp: WordPtr) abi("C") -> Int32:
    ...
