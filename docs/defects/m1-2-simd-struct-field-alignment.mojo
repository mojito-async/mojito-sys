# M1.2 (#124) compiler-defect reproducer: SIMD[DType.uint8, N] embedded as
# a struct field carries hardware VECTOR alignment (matching the SIMD
# width), not the 1-byte alignment a C `unsigned char[N]` array has. This
# silently changes field offsets and total struct size relative to the
# equivalent C struct, with no warning or error from the compiler.
#
# Concretely: a synthetic struct laid out to mirror sockaddr_in6's real
# field shape (u8, u8, u16, u32, <16-byte address>, u32) should be 28
# bytes with the address field at offset 8 (verified against a live C
# oracle in spike/abi/oracle.c / spike/abi/struct_layout_test.mojo). With
# the address field declared as `SIMD[DType.uint8, 16]` it instead comes
# out at offset 16 (8 bytes of unwanted padding) with the whole struct
# inflated to 48 bytes. Swapping to `InlineArray[UInt8, 16]` for the same
# field reproduces the correct C-compatible offset (8) and size (28)
# exactly — this is the fix mojito-sys uses (spike/abi/types.mojo).
#
# Toolchain: Mojo 1.0.0b2 (2cf4d08a), macOS arm64.
#
# Run: mojo run m1-2-simd-struct-field-alignment.mojo
# Expected (bug): "size: 48" / "offset e: 16" instead of the C-correct
# "size: 28" / "offset e: 8".

from std.memory import stack_allocation

struct WithSimdField:
    var a: UInt8
    var b: UInt8
    var c: UInt16
    var d: UInt32
    var e: SIMD[DType.uint8, 16]  # BUG: should be C-compatible offset 8
    var f: UInt32

    def __init__(out self, a: UInt8, b: UInt8, c: UInt16, d: UInt32, f: UInt32):
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = SIMD[DType.uint8, 16](0)
        self.f = f


struct WithInlineArrayField:
    var a: UInt8
    var b: UInt8
    var c: UInt16
    var d: UInt32
    var e: InlineArray[UInt8, 16]  # FIX: C-compatible byte array
    var f: UInt32

    def __init__(out self, a: UInt8, b: UInt8, c: UInt16, d: UInt32, f: UInt32):
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = InlineArray[UInt8, 16](fill=0)
        self.f = f


def main() raises:
    var p1 = stack_allocation[2, WithSimdField]()
    print("SIMD field version:")
    print("  size:", Int(p1 + 1) - Int(p1), "(C-correct answer: 28)")
    var s1 = WithSimdField(1, 2, 3, 4, 5)
    var sp1 = UnsafePointer(to=s1)
    print("  offset e:", Int(UnsafePointer(to=s1.e)) - Int(sp1), "(C-correct answer: 8)")

    var p2 = stack_allocation[2, WithInlineArrayField]()
    print("InlineArray field version:")
    print("  size:", Int(p2 + 1) - Int(p2), "(C-correct answer: 28)")
    var s2 = WithInlineArrayField(1, 2, 3, 4, 5)
    var sp2 = UnsafePointer(to=s2)
    print("  offset e:", Int(UnsafePointer(to=s2.e)) - Int(sp2), "(C-correct answer: 8)")
