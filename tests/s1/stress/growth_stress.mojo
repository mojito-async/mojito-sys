# S1-STRESS-GROWTH — 300 growth/commit cycles on a small stack (issue #31).
#
# Under repeated growth the stack address invariants must hold at every
# step: the low (guard_low) and high (top) boundaries are fixed by the
# reservation, the committed span grows strictly monotonically, and no
# boundary ever moves. This is the worst-case churn for the vm-commit grow
# path.
#
# Then, at the very end, one fork guard pass (t_guard_stress.c, linked in by
# run.sh) verifies the reserved PROT_NONE guard still faults in a child —
# the whole grown stack remains bounded by a live guard page.
#
# Layout (align at rebase if the native stack lane exposes geometry
# differently): [base, base+GUARD) guard; [guard_low=base+GUARD, top] usable.

from std.memory import stack_allocation

comptime BytePtr = UnsafePointer[Byte, MutAnyOrigin]
comptime Out = UnsafePointer[Int, MutAnyOrigin]
comptime Word = UnsafePointer[Int, MutAnyOrigin]

comptime RESERVE_BYTES = 1 << 23        # 8 MiB: INIT_COMMIT + CYCLES pages
comptime INIT_COMMIT = 16 * 1024
comptime GUARD = 16 * 1024              # 1 page
comptime CYCLES = 300
comptime QUANTUM = 0                   # replaced at run time: one host page


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
def _mjs_stack_free(base_slot: Out) abi("C") -> Int32:
    ...


@extern("stress_guard_verdict")
def _guard_verdict(base: Int, guard_bytes: Int) abi("C") -> Int32:
    ...


@extern("exit")
def _c_exit(code: Int32) abi("C"):
    ...


@extern("mjs_page_size")
def _mjs_page_size() abi("C") -> Int32:
    ...


def main():
    # slots[0..2] = base/guard_low/top out-slots; slots[3] = mjs_vm_commit
    # address cell (C reads and advances *addr through it).
    var slots = stack_allocation[4, Int]()
    var rc = _mjs_stack_alloc(
        RESERVE_BYTES, INIT_COMMIT, GUARD, slots, slots + 1, slots + 2
    )
    if rc != 0 or slots[] == 0 or (slots + 1)[] == 0 or (slots + 2)[] == 0:
        print("S1-GROWTH FAIL: mjs_stack_alloc rc=", rc)
        _c_exit(1)

    var base: Int = slots[]
    var guard_low: Int = (slots + 1)[]
    var top: Int = (slots + 2)[]

    # Growth quantum = one host page (16384 on this toolchain): every commit
    # address must stay page-aligned or mprotect inside mjs_vm_commit fails
    # with EINVAL on macOS arm64.
    var quantum = Int(_mjs_page_size())
    if quantum <= 0 or (quantum & (quantum - 1)) != 0:
        print("S1-GROWTH FAIL: mjs_page_size()=", quantum)
        _c_exit(1)

    var committed = INIT_COMMIT
    var prev = 0
    var step = 0
    while step < CYCLES:
        if (guard_low + committed + quantum) > top:
            print("S1-GROWTH FAIL: cycle ", step, " would exceed reservation")
            _c_exit(1)
        (slots + 3)[] = guard_low + committed
        var grc = _mjs_vm_commit(slots + 3, quantum)
        committed += quantum
        if grc != 0:
            print("S1-GROWTH FAIL: mjs_vm_commit rc=", grc, " at cycle ", step)
            _c_exit(1)
        # Frozen ABI contract: on full success C advances the cell exactly
        # past the committed run.
        if (slots + 3)[] != guard_low + committed:
            print(
                "S1-GROWTH FAIL: commit did not advance addr cell at cycle ",
                step,
            )
            _c_exit(1)

        # Non-moving: low (guard_low) and high (top) boundaries fixed at
        # every step.
        if guard_low != (slots + 1)[] or top != (slots + 2)[]:
            print("S1-GROWTH FAIL: stack boundary moved at cycle ", step)
            _c_exit(1)
        # Monotonic: committed strictly grows.
        if committed <= prev:
            print("S1-GROWTH FAIL: committed not strictly monotonic at cycle ", step)
            _c_exit(1)
        prev = committed
        step += 1

    if committed != INIT_COMMIT + CYCLES * quantum:
        print("S1-GROWTH FAIL: final committed mismatch ", committed)
        _c_exit(1)

    # One end guard pass over the whole (grown) stack.
    var verdict = _guard_verdict(base, GUARD)
    if verdict != 0:
        print("S1-GROWTH FAIL: end guard verdict=", verdict)
        _mjs_stack_free(slots)
        _c_exit(1)

    print(
        "S1-GROWTH PASS: ",
        CYCLES,
        " grow/commit cycles; low/high stable every step; total ",
        committed,
        " monotonic; end guard fault clean (SIGBUS/SIGSEGV)",
    )
    _mjs_stack_free(slots)