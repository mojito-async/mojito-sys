# S1-STRESS-GUARD — guarded-stack alignment + guard-page fault (issue #31).
#
# Drives the frozen S1 C ABI directly (@extern, abi("C")):
#   mjs_page_size()
#   mjs_stack_alloc(reserve_bytes, initial_commit_bytes, guard_bytes,
#                   &out_base, &out_guard_low, &out_top)
#   mjs_stack_free(&base)
# and the companion fork probe from tests/s1/stress/t_guard_stress.c (linked
# into this executable by run.sh via -Xlinker).
#
# Requirements under test:
#   1. out_top is 16-byte aligned (AAPCS64 sp-at-entry invariant);
#   2. the single highest usable byte (top-1) is writable — no false fault
#      at the boundary;
#   3. a forked child writing into the FIRST guard_bytes of the reservation
#      (expected PROT_NONE) dies from SIGBUS (arm64/macOS) or SIGSEGV — an
#      immediate contained protection fault, NOT silent adjacent-memory
#      corruption. The guard fault runs in the child so the driver survives.
#
# The mojito-sys dylib resolves at runtime via DYLD_LIBRARY_PATH (see
# run.sh). Until the build/vm/stack lanes land this driver cannot link and
# fails red — the intent of issue #31's TDD-red.

from std.memory import stack_allocation

comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]
comptime Out = UnsafePointer[Int, MutUntrackedOrigin]

comptime RESERVE_BYTES = 256 * 1024
comptime INIT_COMMIT = 16 * 1024
comptime GUARD_PAGES = 1


@extern("mjs_page_size")
def _mjs_page_size() abi("C") -> Int32:
    ...


@extern("mjs_stack_alloc")
def _mjs_stack_alloc(
    reserve_bytes: Int,
    initial_commit_bytes: Int,
    guard_bytes: Int,
    out_base: Out,
    out_guard_low: Out,
    out_top: Out,
) abi("C") -> Int32:
    ...


@extern("mjs_stack_free")
def _mjs_stack_free(base_slot: Out) abi("C"):
    ...


@extern("stress_guard_verdict")
def _guard_verdict(base: Int, guard_bytes: Int) abi("C") -> Int32:
    ...


@extern("exit")
def _c_exit(code: Int32) abi("C"):
    ...


def main():
    var fail = False
    var ps = _mjs_page_size()
    if ps <= 0 or (ps & (ps - 1)) != 0:
        print("S1-GUARD FAIL: mjs_page_size()=", ps, " is not a positive power of two")
        _c_exit(1)

    var guard_bytes = Int(ps) * GUARD_PAGES
    var slots = stack_allocation[3, Int]()
    var rc = _mjs_stack_alloc(
        RESERVE_BYTES, INIT_COMMIT, guard_bytes, slots, slots + 1, slots + 2
    )
    if rc != 0 or slots[] == 0 or (slots + 2)[] == 0:
        print("S1-GUARD FAIL: mjs_stack_alloc rc=", rc)
        _c_exit(1)

    var base: Int = slots[]
    var top: Int = (slots + 2)[]

    if top % 16 != 0:
        print("S1-GUARD FAIL: out_top not 16-byte aligned (top=", top, ")")
        fail = True

    # Highest usable byte (top-1) must be writable: no false boundary fault.
    var hp = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=top - 1)
    hp[] = Byte(0x5a)
    var rd = Int(hp[])
    if rd != 0x5a:
        print("S1-GUARD FAIL: highest usable byte not stably writable (got ", rd, ")")
        fail = True

    if not fail:
        var verdict = _guard_verdict(base, guard_bytes)
        if verdict == 0:
            print(
                "S1-GUARD PASS: top 16-aligned; highest byte writable; "
                "guard write faulted (SIGBUS/SIGSEGV) in child - no silent corruption"
            )
        elif verdict == 1:
            print("S1-GUARD FAIL: child survived writing into the guard page - guard absent or writable")
            fail = True
        elif verdict == 2:
            print("S1-GUARD FAIL: child died from an unexpected signal")
            fail = True
        elif verdict == 3:
            print("S1-GUARD FAIL: fork failed")
            fail = True
        else:
            print("S1-GUARD FAIL: waitpid failed while reaping the probe child")
            fail = True

    _mjs_stack_free(slots)
    if fail:
        _c_exit(1)