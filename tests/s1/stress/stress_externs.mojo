# S1-STRESS shared extern declarations (issue #31, panel review M3).
#
# Single source of truth for every C symbol the stress-lane drivers drive,
# plus the out-slot alias they share. Restating these signatures per driver
# already drifted once (_mjs_stack_free declared void here vs Int32 in the
# frozen header); this module ends that. Drivers import it via run.sh's
# -I <this dir>:
#
#     from stress_externs import ...
#
# Charter (panel conflict resolution): the stress lane drives the frozen
# C ABI DIRECTLY (@extern abi("C")) so pre-merge TDD-red stays self-contained
# and link-verifiable. Growth-path churn additionally mirrors the declared
# production arithmetic of mojito_sys.memory.stack.NativeStack.grow
# (span_start = top - committed - additional; mjs_vm_commit advances the
# cursor upward within the reservation). TODO(issue #30): once
# mojito_sys.memory.stack / .virtual_memory land on main, re-drive the grow
# path through the public NativeStack.grow / VirtualMemory.commit wrappers;
# do NOT fake-import before they exist.
#
# ORIGIN HAZARD (mirrors mojito_sys/memory/stack.mojo): out-slots handed to
# opaque extern calls MUST be MutAnyOrigin — loads through weaker origins get
# hoisted above the call under optimization, so Mojo re-reads stale pre-call
# slot words instead of what C wrote.

comptime OutSlots = UnsafePointer[Int, MutAnyOrigin]


@extern("mjs_page_size")
def mjs_page_size() abi("C") -> Int32:
    ...


@extern("mjs_stack_alloc")
def mjs_stack_alloc(
    reserve_bytes: Int,
    initial_commit_bytes: Int,
    guard_bytes: Int,
    out_base: OutSlots,
    out_guard_low: OutSlots,
    out_top: OutSlots,
) abi("C") -> Int32:
    ...


# Frozen ABI (native/include/mojito_sys.h): int mjs_stack_free(void **base).
@extern("mjs_stack_free")
def mjs_stack_free(base_slot: OutSlots) abi("C") -> Int32:
    ...


# Frozen ABI: int mjs_vm_commit(unsigned char **addr, size_t length).
# addr is a POINTER TO a cell holding the span start; on full success C
# advances the cell past the committed run (0-or-length atomic).
@extern("mjs_vm_commit")
def mjs_vm_commit(addr_cell: OutSlots, length: Int) abi("C") -> Int32:
    ...


# Frozen ABI: int mjs_vm_decommit(unsigned char **addr, size_t length).
# Same cursor contract as mjs_vm_commit; conforming decommit leaves the
# range inaccessible (PROT_NONE) zero-fill-until-recommitted.
@extern("mjs_vm_decommit")
def mjs_vm_decommit(addr_cell: OutSlots, length: Int) abi("C") -> Int32:
    ...


# Companion fork probes from t_guard_stress.c (linked into every driver
# executable by run.sh). Verdict codes documented there.
@extern("stress_guard_verdict")
def stress_guard_verdict(base_word: Int, guard_bytes: Int) abi("C") -> Int32:
    ...


@extern("stress_decommit_verdict")
def stress_decommit_verdict(addr_word: Int) abi("C") -> Int32:
    ...


@extern("exit")
def c_exit(code: Int32) abi("C"):
    ...
