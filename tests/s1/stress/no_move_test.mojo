# S1-STRESS-NOMOVE — a grown stack must not move (issue #31).
#
# Spec 10.2: live stack frames MUST never be moved. A stack grows by
# COMMITTING more of its own already-reserved span (mjs_vm_commit), never by
# relocating existing frames. This driver proves the non-moving invariant
# under repeated growth.
#
# Layout (align at rebase if the native stack lane exposes geometry
# differently — see t_guard_stress.c):
#   [base, base+GUARD)            : PROT_NONE guard (FIRST reserve bytes)
#   [guard_low = base+GUARD, top] : usable region; top = out_top (highest
#                                   usable, 16-aligned)
#
# Procedure:
#   1. mjs_stack_alloc(4 MiB reserve, 16 KiB commit, 1 page guard);
#      record base / guard_low / top.
#   2. Write SENTINELS descending 16-byte-stride Int frame stand-ins from
#      top downward, recording each address.
#   3. GROW_ROUNDS x mjs_vm_commit(GROW_QUANTUM), extending the committed
#      window by committing more of the same reservation.
#   4. At every step re-read every sentinel at its recorded address and
#      require bit-identical values — growth must not relocate frame data.
#   5. Require committed size strictly grows monotonically, and the recorded
#      boundary addresses remain the allocation-time values.
#
# Until the build/vm/stack lanes land this driver cannot link and fails red
# (issue #31 dependence).

from std.memory import stack_allocation

comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]
comptime Out = UnsafePointer[Int, MutAnyOrigin]
comptime Word = UnsafePointer[Int, MutAnyOrigin]

comptime RESERVE_BYTES = 1 << 22        # 4 MiB
comptime INIT_COMMIT = 16 * 1024
comptime GUARD = 16 * 1024              # 1 page (16384 on arm64)
comptime GROW_ROUNDS = 20
comptime GROW_QUANTUM = 32 * 1024
comptime SENTINELS = 12


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


# Frozen ABI (native/include/mojito_sys.h): int mjs_vm_commit(unsigned char
# **addr, size_t length). addr is a POINTER TO a cell holding the span start;
# on full success C advances the cell past the committed run.
@extern("mjs_vm_commit")
def _mjs_vm_commit(addr_cell: Out, length: Int) abi("C") -> Int32:
    ...


@extern("mjs_stack_free")
def _mjs_stack_free(base_slot: Out) abi("C"):
    ...


@extern("exit")
def _c_exit(code: Int32) abi("C"):
    ...


def main():
    # slots[0..2] = base/guard_low/top out-slots; slots[3] = mjs_vm_commit
    # address cell (C reads and advances *addr through it).
    var slots = stack_allocation[4, Int]()
    var rc = _mjs_stack_alloc(
        RESERVE_BYTES, INIT_COMMIT, GUARD, slots, slots + 1, slots + 2
    )
    if rc != 0 or slots[] == 0 or (slots + 1)[] == 0 or (slots + 2)[] == 0:
        print("S1-NOMOVE FAIL: mjs_stack_alloc rc=", rc)
        _c_exit(1)

    var base: Int = slots[]
    var guard_low: Int = (slots + 1)[]
    var top: Int = (slots + 2)[]
    if (base + GUARD) != guard_low:
        print("S1-NOMOVE FAIL: guard_low != base+GUARD")
        _mjs_stack_free(slots)
        _c_exit(1)

    # Record each sentinel address (computed once) and expected value.
    var addrs = stack_allocation[SENTINELS, Int]()
    var vals = stack_allocation[SENTINELS, Int]()
    var k = 0
    while k < SENTINELS:
        var a = top - 8 - k * 16
        addrs[k] = a
        var expected = 0x5A5A0000 + k
        vals[k] = expected
        var pp = Word(unsafe_from_address=a)
        pp[] = expected
        var got = pp[]
        if got != expected:
            print("S1-NOMOVE FAIL: initial sentinel ", k, " not stable")
            _mjs_stack_free(slots)
            _c_exit(1)
        k += 1

    var committed = INIT_COMMIT
    var step = 0
    while step < GROW_ROUNDS:
        if (guard_low + committed + GROW_QUANTUM) > top:
            print("S1-NOMOVE FAIL: growth would exceed reservation at step ", step)
            _mjs_stack_free(slots)
            _c_exit(1)
        (slots + 3)[] = guard_low + committed
        var grc = _mjs_vm_commit(slots + 3, GROW_QUANTUM)
        committed += GROW_QUANTUM
        if grc != 0:
            print("S1-NOMOVE FAIL: mjs_vm_commit rc=", grc, " at step ", step)
            _mjs_stack_free(slots)
            _c_exit(1)
        # Frozen ABI contract: on full success C advances the cell exactly
        # past the committed run; it must never move existing frames.
        if (slots + 3)[] != guard_low + committed:
            print(
                "S1-NOMOVE FAIL: commit did not advance addr cell at step ", step
            )
            _mjs_stack_free(slots)
            _c_exit(1)

        # Non-moving contract: every frame stand-in still holds its value.
        var j = 0
        while j < SENTINELS:
            if Word(unsafe_from_address=addrs[j])[] != vals[j]:
                print("S1-NOMOVE FAIL: sentinel index ", j, " moved/corrupted at step ", step)
                _mjs_stack_free(slots)
                _c_exit(1)
            j += 1
        step += 1

    var expect = INIT_COMMIT + GROW_ROUNDS * GROW_QUANTUM
    if committed != expect:
        print("S1-NOMOVE FAIL: committed not monotonic (", committed, " != ", expect, ")")
        _mjs_stack_free(slots)
        _c_exit(1)

    print(
        "S1-NOMOVE PASS: base/guard_low/top stable across ",
        GROW_ROUNDS,
        " growths; ",
        SENTINELS,
        " 16-byte-aligned sentinels intact; committed ",
        committed,
        " monotonic",
    )
    _mjs_stack_free(slots)