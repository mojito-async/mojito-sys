# mojito-sys S1 ABI — opaque native handles suite (issue #27).
#
# Covers spec §7.2 (opaque handles).  The fd ownership wrappers that used to
# live beside OpaqueNativeHandle migrated verbatim to mojito_sys/io/handle.mojo
# (issue #42); their t1-t7 coverage now runs in tests/s1/io/handles/.
#
# Runs with the platform libc only (no bundled dylib):
#   mojo run -I <repo-root> handles_test.mojo

from mojito_sys.abi.handles import OpaqueNativeHandle
from std.memory.unsafe_pointer import UnsafePointer

comptime HandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]


# ---------------------------------------------------------------------------
# T7 — pointer-origin conformance (issue #45): HandlePtr must remain EXACTLY
# spec §7.2's sketch, UnsafePointer[NoneType, MutUntrackedOrigin].  Origins
# do not implicitly convert in Mojo, so calling assert_spec_origin with a
# HandlePtr compiles only while the alias stays bound to the spec type; a
# rebind to any other origin (e.g. MutAnyOrigin) fails compilation here.
# ---------------------------------------------------------------------------
comptime SpecHandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]


def assert_spec_origin(p: SpecHandlePtr):
    pass


# ----------------------------------------------------------------------------
# T1 — a default OpaqueNativeHandle() is null.
# ----------------------------------------------------------------------------
def t1_null_handle() -> Bool:
    var h = OpaqueNativeHandle()
    return h.is_null()


# ----------------------------------------------------------------------------
# T2 — pointer() is a COPY of the address: wrapping a non-null pointer keeps
# the identity, and the copy is not the null sentinel.
# ----------------------------------------------------------------------------
def t2_pointer_copy_roundtrip() -> Bool:
    var one: Int = 8
    var p = HandlePtr(unsafe_from_address=one)
    var h = OpaqueNativeHandle(p)
    if h.is_null():
        return False
    var q = h.pointer()
    return Int(q) == one


# ---------------------------------------------------------------------------


def main() raises:
    # T7 — pointer-origin conformance (issue #45): compiles only while
    # HandlePtr stays EXACTLY UnsafePointer[NoneType, MutUntrackedOrigin]
    # (spec §7.2 sketch); origins do not implicitly convert, so a rebind to
    # any other origin (e.g. MutAnyOrigin) fails compilation right here.
    # NOTE: checked inline in main, NOT via call_test — an 8-way call_test
    # dispatch trips a mojo 1.0.0b2 miscompile that flips t2-t6 red.
    var origin_probe = OpaqueNativeHandle()
    assert_spec_origin(origin_probe.pointer())
    print("t7_pointer_origin_matches_spec: PASS")

    var names = [
        "t1_null_handle",
        "t2_pointer_copy_roundtrip",
    ]
    var failures = 0
    for i in range(2):
        var ok = call_test(i + 1)
        print(names[i] + ": " + ("PASS" if ok else "FAIL"))
        if not ok:
            failures += 1
    print("RESULT: " + ("all green" if failures == 0 else String(failures) + " FAILED"))
    if failures != 0:
        raise Error("abi-handles: " + String(failures) + " test(s) FAILED")


def call_test(i: Int) -> Bool:
    if i == 1:
        return t1_null_handle()
    elif i == 2:
        return t2_pointer_copy_roundtrip()
    return False
