# S1-STRESS-NOMOVE-TEST — a grown stack must not move (issue #31).
#
# Spec 10.2: live stack frames MUST never be moved. A stack grows by
# COMMITTING more of its own already-reserved span (mjs_vm_commit), never by
# relocating existing frames. Growth follows the declared production model
# of NativeStack.grow (issue #30): the committed span is [top - committed,
# top) and extends DOWNWARD; mjs_vm_commit's cursor advances upward within
# the reservation. TODO(issue #30): re-drive the grow path through the
# public NativeStack.grow wrapper once mojito_sys.memory.stack lands on
# main; until then this mirrors its arithmetic byte-for-byte.
#
# Layout (production, native/posix/mjs_stack.c):
#   [base, base+guard)            : PROT_NONE guard (first guard bytes)
#   [guard_low = base+guard, top] : usable region; top = highest usable,
#                                   16-aligned; committed span at TOP.
#
# Procedure:
#   1. mjs_stack_alloc(4 MiB usable, 16 KiB commit request, 1 page guard);
#      record base / guard_low / top (geometry derived from mjs_page_size).
#   2. Write SENTINELS descending 16-byte-stride frame stand-ins from top
#      downward, recording each address.
#   3. GROW_ROUNDS x downward commit of one page: first-touch zero-fill
#      check on each fresh page BEFORE writing, then a marker write that
#      must persist across later rounds.
#   4. At every step re-read every sentinel at its recorded address and
#      require bit-identical values — growth must not relocate frame data.
#   5. Negative controls pinning the oracle's blind spots:
#      a) relocation blind spot — MADV_FREE laziness can keep old bytes
#         READABLE after backing is dropped, so sentinel re-reads alone
#         could pass a content-preserving relocation. The driver decommits
#         a fresh page via its OWN conforming mjs_vm_decommit and requires
#         stress_decommit_verdict to report a contained fault; a readable
#         decommitted page means the oracle is blind and the suite says so.
#      b) over-commit blind spot — reading the page just BELOW the initial
#         committed window must fault; an allocator that pre-commits the
#         whole usable span is caught before any growth round runs.

from std.memory import stack_allocation

from stress_externs import (
    c_exit,
    mjs_page_size,
    mjs_stack_alloc,
    mjs_stack_free,
    mjs_vm_commit,
    mjs_vm_decommit,
    stress_decommit_verdict,
)

comptime RESERVE_BYTES = 1 << 22        # usable span: 4 MiB (page multiple)
comptime INIT_COMMIT_REQ = 16 * 1024    # request; C rounds up to pages
comptime GROW_ROUNDS = 20
comptime SENTINELS = 12


def round_up_to_page(n: Int, ps: Int) -> Int:
    return (n + ps - 1) // ps * ps


def main():
    var ps = Int(mjs_page_size())
    if ps <= 0 or (ps & (ps - 1)) != 0:
        print("S1-NOMOVE FAIL: mjs_page_size()=", ps)
        c_exit(1)

    var quantum = ps                       # one host page per round
    var guard_bytes = ps

    # slots[0..2] = base/guard_low/top out-slots; slots[3] = commit cursor
    # cell (C reads and advances *addr through it); slots[4] = decommit
    # cursor cell for the negative control.
    var slots = stack_allocation[5, Int]()
    var rc = mjs_stack_alloc(
        RESERVE_BYTES, INIT_COMMIT_REQ, guard_bytes, slots, slots + 1, slots + 2
    )
    if rc != 0 or slots[] == 0 or (slots + 1)[] == 0 or (slots + 2)[] == 0:
        print("S1-NOMOVE FAIL: mjs_stack_alloc rc=", rc)
        c_exit(1)

    var base: Int = slots[]
    var guard_low: Int = (slots + 1)[]
    var top: Int = (slots + 2)[]
    if (base + guard_bytes) != guard_low:
        print("S1-NOMOVE FAIL: guard_low != base+guard")
        mjs_stack_free(slots)
        c_exit(1)

    # Record each sentinel address (computed once) and expected value.
    # Sentinels live inside the initially committed top span.
    var committed = round_up_to_page(INIT_COMMIT_REQ, ps)
    if SENTINELS * 16 > committed:
        print("S1-NOMOVE FAIL: sentinels exceed initial commit ", committed)
        mjs_stack_free(slots)
        c_exit(1)
    var addrs = stack_allocation[SENTINELS, Int]()
    var vals = stack_allocation[SENTINELS, Int]()
    var k = 0
    while k < SENTINELS:
        var a = top - 8 - k * 16
        addrs[k] = a
        var expected = 0x5A5A0000 + k
        vals[k] = expected
        var pp = UnsafePointer[Int, MutAnyOrigin](unsafe_from_address=a)
        pp[] = expected
        if pp[] != expected:
            print("S1-NOMOVE FAIL: initial sentinel ", k, " not stable")
            mjs_stack_free(slots)
            c_exit(1)
        k += 1

    # Over-commit control (review mutant B): the span just BELOW the
    # initial committed window must still be reserved-but-uncommitted.
    # Reading it must fault in the fork child; a child that survives means
    # the allocator over-committed the reservation and the oracle would
    var below_span = top - committed - 1
    var oc = stress_decommit_verdict(below_span)
    if oc != 0:
        print(
            "S1-NOMOVE FAIL: over-commit control verdict=", oc,
            " — page below initial commit already accessible",
        )
        mjs_stack_free(slots)
        c_exit(1)

    # Fresh-page marker addresses/values, one per growth round.
    var marks = stack_allocation[GROW_ROUNDS, Int]()

    var step = 0
    while step < GROW_ROUNDS:
        # Production NativeStack.grow arithmetic (issue #30): extend DOWNWARD.
        var span_start = top - committed - quantum
        var cell = (slots + 3)
        cell[] = span_start
        var grc = mjs_vm_commit(cell, quantum)
        if grc != 0:
            print("S1-NOMOVE FAIL: mjs_vm_commit rc=", grc, " at step ", step)
            mjs_stack_free(slots)
            c_exit(1)
        if cell[] != top - committed:
            print("S1-NOMOVE FAIL: cursor did not advance as declared at step ",
                step,
            )
            mjs_stack_free(slots)
            c_exit(1)

        # First touch: fresh anonymous commit reads zero-fill before write.
        var fp = UnsafePointer[Byte, MutAnyOrigin](unsafe_from_address=span_start)
        if Int(fp[]) != 0:
            print(
                "S1-NOMOVE FAIL: fresh commit not zero-fill at step ", step
            )
            mjs_stack_free(slots)
            c_exit(1)
        fp[] = Byte((step % 251) + 1)
        marks[step] = span_start
        if step > 0:
            var prev = UnsafePointer[Byte, MutAnyOrigin](
                unsafe_from_address=marks[step - 1]
            )
            if Int(prev[]) != ((step - 1) % 251) + 1:
                print("S1-NOMOVE FAIL: earlier marker corrupted at step ", step)
                mjs_stack_free(slots)
                c_exit(1)

        committed += quantum
        # Non-moving contract: every frame stand-in still holds its value;
        # boundaries remain the allocation-time addresses.
        var j = 0
        while j < SENTINELS:
            if (
                UnsafePointer[Int, MutAnyOrigin](
                    unsafe_from_address=addrs[j]
                )[]
                != vals[j]
            ):
                print(
                    "S1-NOMOVE FAIL: sentinel index ", j,
                    " moved/corrupted at step ", step,
                )
                mjs_stack_free(slots)
                c_exit(1)
            j += 1
        if guard_low != (slots + 1)[] or top != (slots + 2)[]:
            print("S1-NOMOVE FAIL: boundary moved at step ", step)
            mjs_stack_free(slots)
            c_exit(1)
        step += 1

    if committed != round_up_to_page(INIT_COMMIT_REQ, ps) + GROW_ROUNDS * quantum:
        print("S1-NOMOVE FAIL: committed bookkeeping mismatch (", committed, ")")
        mjs_stack_free(slots)
        c_exit(1)

    # Negative control: the project's own conforming decommit must flip the
    # oracle loud — reading a decommitted page faults in the fork child, it
    # must NOT silently return stale (MADV_FREE-lazy) bytes.
    var ctrl_cell = (slots + 4)
    ctrl_cell[] = marks[GROW_ROUNDS - 1]
    var drc = mjs_vm_decommit(ctrl_cell, quantum)
    if drc != 0 or ctrl_cell[] != marks[GROW_ROUNDS - 1] + quantum:
        print("S1-NOMOVE FAIL: mjs_vm_decommit rc=", drc)
        mjs_stack_free(slots)
        c_exit(1)
    var verdict = stress_decommit_verdict(marks[GROW_ROUNDS - 1])
    if verdict != 0:
        print(
            "S1-NOMOVE FAIL: decommit negative-control verdict=", verdict,
            " — oracle blind: decommitted page still readable",
        )
        mjs_stack_free(slots)
        c_exit(1)

    # Decommit must not disturb neighbours: sentinels and surviving markers
    # are still bit-intact afterwards.
    k = 0
    while k < SENTINELS:
        if (
            UnsafePointer[Int, MutAnyOrigin](unsafe_from_address=addrs[k])[]
            != vals[k]
        ):
            print("S1-NOMOVE FAIL: post-decommit sentinel drift")
            mjs_stack_free(slots)
            c_exit(1)
        k += 1

    print(
        "S1-NOMOVE PASS: boundaries stable across ",
        GROW_ROUNDS,
        " downward growths; ",
        SENTINELS,
        " sentinels intact; first-touch zero-fill held; "
        + "decommit control faults loud",
    )
    mjs_stack_free(slots)
    print("RESULT: S1-NOMOVE green")
