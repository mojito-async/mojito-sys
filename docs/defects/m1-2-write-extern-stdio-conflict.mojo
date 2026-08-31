# M1.2 (#124) compiler-defect reproducer: a module that also uses
# `print()` (or any std.io write path) cannot declare its OWN
# `@extern("write")` binding, even when its signature is made to match
# EXACTLY what the standard library's own internal binding uses
# (std/io/file_descriptor.mojo — FileDescriptor.write). Mojo's extern
# mechanism treats the C SYMBOL NAME as the uniqueness key across the
# WHOLE compiled program, not per module.
#
# Bisection history (each step's outcome is what motivates the next):
#   1. `count: UInt64 -> Int64` (fixed-width types) fails LLVM lowering
#      with "existing function with conflicting signature" the moment
#      the custom write() binding is actually CALLED alongside any
#      print()/FileDescriptor.write() use elsewhere in the program (an
#      UNCALLED declaration is dead-code-eliminated and never trips
#      this — cost real time to find, since an earlier smoke test that
#      only declared, never called, looked like a false "this works").
#   2. Matching the stdlib's own WORD-SIZED types (`Int`/`UInt`, not
#      Int64/UInt64 — confirmed to be what the stdlib itself uses, since
#      only a width match still fails at step 1's error) gets past the
#      signature check but fails one step further with "existing
#      function with conflicting attributes" once the call site is
#      exercised.
#   3. Matching the pointer type too (`UnsafePointer[NoneType,
#      MutAnyOrigin]`, i.e. `pointer<none>` at the MLIR level, matching
#      the stdlib's own opaque pointer) still does not clear the
#      "conflicting attributes" error. Nothing in the bundled Modular
#      guidance names what attribute differs or how to set it via
#      `@extern`/`abi("C")`.
#
# Toolchain: Mojo 1.0.0b2 (2cf4d08a), macOS arm64.
#
# Run: mojo run m1-2-write-extern-stdio-conflict.mojo
# Expected (bug): fails to lower with
#   "existing function with conflicting attributes"
# citing oss/modular/mojo/stdlib/std/io/file_descriptor.mojo as the
# conflicting declaration, even though every observable type in this
# file's own declaration has been bisected to match the stdlib's.

from std.memory import stack_allocation

comptime OpaqueBuf = UnsafePointer[NoneType, MutAnyOrigin]

@extern("write")
def mjo_write(fd: Int, buf: OpaqueBuf, count: Int) abi("C") -> Int: ...


def main() raises:
    print("this print() pulls in the stdlib's own write() binding")
    var buf = stack_allocation[4, Byte]()
    buf[0] = 65
    # Actually CALLING the custom binding (not just declaring it) is what
    # trips the conflict — an uncalled declaration is silently dropped.
    var n = mjo_write(1, buf.bitcast[NoneType](), 1)
    print("wrote", n, "bytes via the custom binding")
