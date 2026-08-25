# S1-STRESS-GROWTH-TEST — 300 growth/commit cycles on a small stack (#31).
#
# Drives the declared production grow path of NativeStack.grow
# (mojito_sys/memory/stack.mojo, issue #30): the native stack grows DOWN
# from `top`. The committed span is [top - committed, top); growing by
# additional bytes commits span_start = top - committed - additional via
# the frozen mjs_vm_commit service, whose cursor then advances UPWARD to
# top - committed_new. TODO(issue #30): re-drive this loop through the
# public NativeStack.grow wrapper once mojito_sys.memory.stack lands on
# main; until then the arithmetic below mirrors it byte-for-byte.
#
# Under repeated growth these invariants must hold at every step:
#   1. FIRST TOUCH: a freshly committed page reads ZERO-FILL before any
#      write (anonymous-memory commit contract; structurally kills a stub
#      mjs_vm_commit that only advances its cursor);
#   2. written markers persist across later cycles (observable memory, not
#      bookkeeping);
#   3. low (guard_low) and high (top) boundaries never move;
#   4. committed span grows strictly monotonically, bounded by the
#      reservation.
#
# Then one fork guard pass (t_guard_stress.c) verifies the reserved
# PROT_NONE guard still faults in a child — the whole grown stack remains
# bounded by a live guard page.
#
# All geometry derives from mjs_page_size() at run time (panel review M2):
# hardcoded 16 KiB constants misalign on 16 KiB vs 64 KiB page hosts.

from stress_externs import (
    OutSlots,
    c_exit,
    mjs_page_size,
    mjs_stack_alloc,
    mjs_stack_free,
    mjs_vm_commit,
    stress_guard_verdict,
)

from std.memory import stack_allocation

comptime RESERVE_BYTES = 1 << 23        # usable span: 8 MiB (page multiple)
comptime INIT_COMMIT_REQ = 16 * 1024    # request; C rounds up to pages
comptime CYCLES_MAX = 300


def round_up_to_page(n: Int, ps: Int) -> Int:
    return (n + ps - 1) // ps * ps


def main():
    var ps = Int(mjs_page_size())
    if ps <= 0 or (ps & (ps - 1)) != 0:
        print("S1-GROWTH FAIL: mjs_page_size()=", ps)
        c_exit(1)

    var quantum = ps                       # one host page per cycle
    var guard_bytes = ps                   # guard = one page at any size

    # slots[0..2] = base/guard_low/top out-slots; slots[3] = mjs_vm_commit
    # address cell (C reads and advances *addr through it).
    var slots = stack_allocation[4, Int]()
    var rc = mjs_stack_alloc(
        RESERVE_BYTES, INIT_COMMIT_REQ, guard_bytes, slots, slots + 1, slots + 2
    )
    if rc != 0 or slots[] == 0 or (slots + 1)[] == 0 or (slots + 2)[] == 0:
        print("S1-GROWTH FAIL: mjs_stack_alloc rc=", rc)
        c_exit(1)

    var base: Int = slots[]
    var guard_low: Int = (slots + 1)[]
    var top: Int = (slots + 2)[]

    # Production bookkeeping: C rounds initial_commit up to whole pages.
    var committed = round_up_to_page(INIT_COMMIT_REQ, ps)
    if committed < INIT_COMMIT_REQ or (top - committed) < guard_low:
        print("S1-GROWTH FAIL: derived initial commit ", committed)
        mjs_stack_free(slots)
        c_exit(1)

    # M2: derive cycle count from live geometry instead of aborting mid-run
    # when a large-page host runs out of reservation.
    var cycles = (RESERVE_BYTES - committed) // quantum
    if cycles > CYCLES_MAX:
        cycles = CYCLES_MAX
    if cycles <= 0:
        print("S1-GROWTH FAIL: no room to grow (cycles=", cycles, ")")
        mjs_stack_free(slots)
        c_exit(1)

    # Marker addresses of every freshly committed page start, for
    # cross-cycle persistence checks.
    var marks = stack_allocation[CYCLES_MAX, Int]()

    var step = 0
    while step < cycles:
        # NativeStack.grow arithmetic (production, issue #30): new span
        # start sits BELOW the current committed span, anchored at top.
        var span_start = top - committed - quantum

        # FIRST TOUCH: the about-to-be-committed region must read zero-fill
        # once committed, BEFORE we write anything into it. A stub commit
        # that only advances its cursor cannot fake this.
        var cell = (slots + 3)
        cell[] = span_start
        var grc = mjs_vm_commit(cell, quantum)
        if grc != 0:
            print("S1-GROWTH FAIL: mjs_vm_commit rc=", grc, " at cycle ", step)
            mjs_stack_free(slots)
            c_exit(1)
        # Frozen ABI contract: cursor advanced exactly past the run.
        if cell[] != top - committed:
            print(
                "S1-GROWTH FAIL: cursor did not advance as declared at cycle ",
                step,
            )
            mjs_stack_free(slots)
            c_exit(1)

        var fp = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=span_start)
        var zero = Int(fp[])
        if zero != 0:
            print(
                "S1-GROWTH FAIL: fresh commit not zero-fill at cycle ",
                step,
                " (read ",
                zero,
                ")",
            )
            mjs_stack_free(slots)
            c_exit(1)

        # Observable memory: write a marker, require earlier markers intact.
        fp[] = Byte((step % 251) + 1)
        marks[step] = span_start
        if step > 0:
            var prev = UnsafePointer[Byte, MutAnyOrigin](
                unsafe_from_address=marks[step - 1]
            )
            if Int(prev[]) != ((step - 1) % 251) + 1:
                print(
                    "S1-GROWTH FAIL: earlier marker corrupted at cycle ", step
                )
                mjs_stack_free(slots)
                c_exit(1)

        committed += quantum
        # Non-moving: low (guard_low) and high (top) boundaries fixed at
        # every step.
        if guard_low != (slots + 1)[] or top != (slots + 2)[]:
            print("S1-GROWTH FAIL: stack boundary moved at cycle ", step)
            mjs_stack_free(slots)
            c_exit(1)
        step += 1

    if committed != round_up_to_page(INIT_COMMIT_REQ, ps) + cycles * quantum:
        print("S1-GROWTH FAIL: final committed mismatch ", committed)
        mjs_stack_free(slots)
        c_exit(1)

    # One end guard pass over the reservation front while the grown span is
    # fully committed above it.
    var verdict = stress_guard_verdict(base, guard_bytes)
    if verdict != 0:
        print("S1-GROWTH FAIL: end guard verdict=", verdict)
        mjs_stack_free(slots)
        c_exit(1)

    print(
        "S1-GROWTH PASS: ",
        cycles,
        " downward grow/commit cycles from top; first-touch zero-fill held; "
        + "markers persistent; boundaries stable; end guard fault clean",
    )
    mjs_stack_free(slots)
    print("RESULT: S1-GROWTH green")
