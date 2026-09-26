# spike/runtime/thread_test.mojo — M1.3 (#126) runtime spike: native thread
# entry from Mojo, no C trampoline anywhere in the chain.
#
# This is deliberately NOT mojito_sys.thread.thread's spawn_native_thread():
# that wrapper calls mjs_thread_spawn (native/posix/mjs_thread.c), whose own
# C trampoline (mjs_thread_trampoline) is the actual pthread_create start
# routine and calls the Mojo entry only AFTER the C layer has already run.
# #126 asks the harder question: can a Mojo abi("C") def be the ACTUAL
# start_routine pthread_create invokes, with nothing native in between?
# This file answers that directly, against externs_leaf.mojo's raw
# pthread_create/pthread_join bindings.
#
# TDD note: every check below was proven red-then-green during development
# by hand-written throwaway probes before this file was assembled (see
# FINDINGS.md's "process" section) — three genuine reds surfaced along the
# way and are recorded there: an `abi("C") raises` compile-time rejection,
# a `owned existing: Self` __moveinit__ parameter form b2 does not parse
# (the repo's dominant `mut self, mut existing: Self` shape does), and the
# `unsafe_from_address=0` literal rejection (b2-wide, already documented in
# mojito_sys/abi/callbacks.mojo) — the fix each time is recorded inline
# below at its point of use.
#
# Acceptance criteria this file targets (issue #126, thread half):
#   T1  entry runs on a pthread_create thread; arg round-trips both via the
#       pointer's own mutation and via pthread_join's retval, clean join;
#   T2  distinct entry-return values survive pthread_join exactly;
#   T3  a Movable Mojo value's __del__ fires on a spawned thread exactly as
#       on the main thread (construct/destruct balance always returns to
#       0), INCLUDING when the entry takes the try/except containment path;
#   T4  a value using __deinit__ (not __del__) does NOT fire on scope exit
#       on a spawned thread OR on the main thread — parity with the
#       already-documented b2 finding in mojito_sys/ctx/context.mojo
#       ("b2 1.0.0b2 does not invoke __deinit__ on locals"). This is the
#       "or the difference is documented" branch of the acceptance
#       criterion, not a new defect: __del__ is this toolchain's working
#       destructor hook (repo-wide: mojito_sys/io/{socket,handle}.mojo both
#       use `__del__(deinit self)`, not `__deinit__`, as their real release
#       path) and it behaves identically on both threads;
#   T5  an entry that raises internally is CONTAINED: caught by an internal
#       try/except and reported via the (non-raising) return value, never
#       propagating past the abi("C") boundary. `abi("C") raises` itself is
#       rejected by the compiler at PARSE time (verified separately, see
#       FINDINGS.md) — so the unwind-into-C failure mode #126 asks about is
#       actually unreachable here: there is no way to even express a
#       raising abi("C") entry, which is a stronger guarantee than "it is
#       contained at runtime";
#   T6  pthread_self() differs between the main thread and a spawned one,
#       and is stable within a thread;
#   T7  50 sequential spawn/join cycles complete with exact results (leak-
#       clean smoke, mirroring tests/s2/thread/thread_test.mojo's #8).
#
# Run via spike/runtime/run.sh (builds spike/runtime/oracle.c ad hoc, no
# Makefile change — same convention as spike/abi/run.sh). Green requires
# the exact "RESULT: all green" line.

from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

import externs_leaf as ext

comptime I64Ptr = UnsafePointer[Int64, MutAnyOrigin]
comptime U64Ptr = UnsafePointer[UInt64, MutAnyOrigin]


# Code address of an @export'd abi("C") def as a raw pointer — the adrp/add
# idiom proven in tests/s1/abi/callbacks/conformance_test.mojo, reused
# verbatim (Apple arm64 Mach-O only; see README.md's platform note).
def entry_pointer[symbol_name: String]() -> ext.EntryCodePtr:
    # PORTABLE across macOS (Mach-O) and Linux (ELF), both AArch64: the two
    # object formats need different adrp/add relocation syntax for the same
    # ADRP+ADD page-address idiom -- Mach-O wants a leading `_` symbol
    # prefix and `@PAGE`/`@PAGEOFF`; ELF wants no prefix and `:lo12:`
    # instead of `@PAGEOFF` (plain adrp with no suffix at all for the high
    # part). This comptime branch is a genuinely NEW finding this leg
    # verified for real on native Linux/AArch64 (a docker container on the
    # arm64 dev host, see README.md) -- #124's own version of this idiom
    # was Apple-arm64-only and never actually ran on any Linux host either
    # (the CI wall blocked it). x86-64 would need a THIRD, ISA-different
    # form (`lea`) not attempted here -- see README.md's portability note.
    comptime is_macos = CompilationTarget().is_macos()
    comptime asm_str = (
        "adrp ${0:x}, _" + symbol_name + "@PAGE\n"
        "add ${0:x}, ${0:x}, _" + symbol_name + "@PAGEOFF\n"
    ) if is_macos else (
        "adrp ${0:x}, " + symbol_name + "\n"
        "add ${0:x}, ${0:x}, :lo12:" + symbol_name + "\n"
    )
    var addr = inlined_assembly[asm_str, UInt, constraints="=r"]()
    return ext.EntryCodePtr(unsafe_from_address=Int(addr))


def _null_attr() -> ext.PthreadAttrPtr:
    var zero = 0
    return ext.PthreadAttrPtr(unsafe_from_address=zero)


# Spawn `entry(arg)` via a DIRECT pthread_create call (no mjs_thread_spawn
# anywhere), join it, and write results into the caller's 3-slot `out`
# buffer: out[0]=create_rc, out[1]=join_rc, out[2]=retval. (b2's Tuple
# constructor rejects a mixed Int32/UInt64 literal tuple return here — "could
# not convert element ... to expected type 'Movable'" — so results travel
# through a caller-owned out-buffer instead, matching this repo's own
# out-slot convention rather than fighting the tuple constructor.)
def spawn_and_join(
    entry: ext.EntryCodePtr, arg: ext.ArgPtr, results: UnsafePointer[Int64, MutAnyOrigin]
):
    var tslot = stack_allocation[1, UInt64]()
    tslot[0] = 0
    var crc = ext.probe_pthread_create(tslot, _null_attr(), entry, arg)
    results[0] = Int64(crc)
    if crc != 0:
        results[1] = 0
        results[2] = 0
        return
    var retval = stack_allocation[1, UInt64]()
    retval[0] = 0
    var jrc = ext.probe_pthread_join(tslot[0], retval)
    results[1] = Int64(jrc)
    results[2] = Int64(retval[0])


def check(name: String, ok: Bool) -> Bool:
    print(name + ": " + ("PASS" if ok else "FAIL"))
    return ok


# ---- T1/T2: arg + result round trip, clean join ----------------------------

@export("m13_thr_roundtrip_entry")
def m13_thr_roundtrip_entry(arg: I64Ptr) abi("C") -> UInt64:
    # arg[0] is both an input and an output: the child mutates it in place
    # (proves the pointer handed in arrives intact) and also returns a
    # value derived from it (proves the RETURN survives pthread_join
    # independently of the pointer mutation).
    arg[0] = arg[0] * 2 + 1
    return UInt64(arg[0])


# ---- T3: __del__ fires on a spawned thread, parity with main thread -------

struct DelCounted(Movable):
    """Constructs/destructs via __del__ (this toolchain's WORKING release
    hook — see mojito_sys/io/socket.mojo / io/handle.mojo precedent)."""

    var slot: I64Ptr

    def __init__(out self, slot: I64Ptr):
        self.slot = slot
        self.slot[0] += 1

    def __moveinit__(mut self, mut existing: Self):
        self.slot = existing.slot

    def __del__(deinit self):
        self.slot[0] -= 1


# ---- T4: __deinit__ does NOT fire on scope exit (parity, documented) -----

struct DeinitCounted(Movable):
    """Same shape as DelCounted but uses __deinit__ — mirrors
    mojito_sys/ctx/context.mojo's already-documented b2 finding that
    __deinit__ is not invoked on locals. Tested here for THREAD PARITY,
    not to re-discover the (already known) limitation itself."""

    var slot: I64Ptr

    def __init__(out self, slot: I64Ptr):
        self.slot = slot
        self.slot[0] += 1

    def __moveinit__(mut self, mut existing: Self):
        self.slot = existing.slot

    def __deinit__(deinit self):
        self.slot[0] -= 1


@export("m13_thr_del_entry")
def m13_thr_del_entry(arg: I64Ptr) abi("C") -> UInt64:
    var c = DelCounted(arg)
    _ = c.slot  # keep `c` alive to end of scope; balance checked by caller
    return 0


@export("m13_thr_deinit_entry")
def m13_thr_deinit_entry(arg: I64Ptr) abi("C") -> UInt64:
    var c = DeinitCounted(arg)
    _ = c.slot
    return 0


# ---- T5: raise inside the entry is CONTAINED, never unwinds into C -------
# NOTE: `abi("C") raises` is rejected at PARSE time in Mojo 1.0.0b2
# ("'abi("C")' function may not be marked 'raises'; remove 'raises' or use
# 'abi("Mojo")'") — verified directly, not assumed; see FINDINGS.md. So the
# ONLY expressible shape for a pthread entry that calls raising Mojo code is
# the one below: catch internally, report through the ordinary return
# value. There is no way to write the unsafe shape at all.


def _raises_if_nonzero(x: Int64) raises -> Int64:
    if x != 0:
        raise Error("m13 intentional failure, tag=" + String(x))
    return 0


@export("m13_thr_raise_entry")
def m13_thr_raise_entry(arg: I64Ptr) abi("C") -> UInt64:
    # arg[0]: should-raise tag (0 = no raise). arg[1]: ctor/dtor balance
    # cell for a value constructed alongside the try/except, proving
    # cleanup still runs correctly along the exception-handling path.
    var balance_slot = (arg + 1)
    var c = DelCounted(balance_slot)
    var status: UInt64 = 0
    try:
        _ = _raises_if_nonzero(arg[0])
    except e:
        status = 1
    _ = c.slot
    return status


# ---- T6: pthread_self differs across threads, stable within one ----------

@export("m13_thr_self_entry")
def m13_thr_self_entry(arg: U64Ptr) abi("C") -> UInt64:
    var id1 = ext.probe_pthread_self()
    var id2 = ext.probe_pthread_self()
    arg[0] = id1
    arg[1] = id2
    return id1


def main() raises:
    var failed = 0
    var res = stack_allocation[3, Int64]()

    # ---- T1/T2: round trip + distinct return values -----------------------
    var rt_entry = entry_pointer["m13_thr_roundtrip_entry"]()
    var cases_ok = True
    var seed = 5
    while seed < 8:
        var cell = stack_allocation[1, Int64]()
        cell[0] = Int64(seed)
        spawn_and_join(rt_entry, ext.ArgPtr(unsafe_from_address=Int(cell)), res)
        var want = Int64(seed) * 2 + 1
        if res[0] != 0 or res[1] != 0 or res[2] != want or cell[0] != want:
            cases_ok = False
        seed += 1
    if not check("T1/T2 arg+result round trip across pthread_create/join (3 seeds)", cases_ok):
        failed += 1

    # ---- T3: __del__ fires on a spawned thread (balance returns to 0) -----
    var del_entry = entry_pointer["m13_thr_del_entry"]()
    var del_cell = stack_allocation[1, Int64]()
    del_cell[0] = 0
    spawn_and_join(del_entry, ext.ArgPtr(unsafe_from_address=Int(del_cell)), res)
    if not check(
        "T3 __del__ fires on spawned thread (ctor+dtor balance == 0)",
        res[0] == 0 and res[1] == 0 and del_cell[0] == 0,
    ):
        failed += 1

    # ---- T4: __deinit__ does NOT fire on a spawned thread (parity) --------
    var deinit_entry = entry_pointer["m13_thr_deinit_entry"]()
    var deinit_cell = stack_allocation[1, Int64]()
    deinit_cell[0] = 0
    spawn_and_join(deinit_entry, ext.ArgPtr(unsafe_from_address=Int(deinit_cell)), res)
    if not check(
        "T4 __deinit__ does NOT fire on spawned thread either (balance == 1,"
        " parity with mojito_sys/ctx/context.mojo's main-thread finding)",
        res[0] == 0 and res[1] == 0 and deinit_cell[0] == 1,
    ):
        failed += 1

    # ---- T5: contained raise, entry reports failure, process stays alive --
    var raise_entry = entry_pointer["m13_thr_raise_entry"]()

    var okA = stack_allocation[2, Int64]()
    okA[0] = 0
    okA[1] = 0
    spawn_and_join(raise_entry, ext.ArgPtr(unsafe_from_address=Int(okA)), res)
    var caseA_ok = res[0] == 0 and res[1] == 0 and res[2] == 0 and okA[1] == 0

    var okB = stack_allocation[2, Int64]()
    okB[0] = 42
    okB[1] = 0
    spawn_and_join(raise_entry, ext.ArgPtr(unsafe_from_address=Int(okB)), res)
    var caseB_ok = res[0] == 0 and res[1] == 0 and res[2] != 0 and okB[1] == 0

    if not check(
        "T5 entry-internal raise contained: no-raise path clean, raise"
        " path reports failure via return value, cleanup still balanced,"
        " process still alive",
        caseA_ok and caseB_ok,
    ):
        failed += 1

    # ---- T6: thread identity differs from main, stable within the thread --
    var self_entry = entry_pointer["m13_thr_self_entry"]()
    var ids = stack_allocation[2, UInt64]()
    ids[0] = 0
    ids[1] = 0
    spawn_and_join(self_entry, ext.ArgPtr(unsafe_from_address=Int(ids)), res)
    var main_id = ext.probe_pthread_self()
    if not check(
        "T6 spawned-thread id stable within itself and != main thread id",
        res[0] == 0
        and res[1] == 0
        and UInt64(res[2]) == ids[0]
        and ids[0] == ids[1]
        and ids[0] != main_id
        and ids[0] != 0,
    ):
        failed += 1

    # ---- T7: 50 sequential spawn/join cycles, exact results, no leak-smoke -
    var cycles_ok = True
    var cyc = 0
    while cyc < 50:
        var ccell = stack_allocation[1, Int64]()
        ccell[0] = Int64(cyc)
        spawn_and_join(rt_entry, ext.ArgPtr(unsafe_from_address=Int(ccell)), res)
        if res[0] != 0 or res[1] != 0 or res[2] != Int64(cyc) * 2 + 1:
            cycles_ok = False
        cyc += 1
    if not check("T7 50 sequential spawn/join cycles, exact results", cycles_ok):
        failed += 1

    print("RESULT: " + ("all green" if failed == 0 else String(failed) + " FAILED"))
    if failed != 0:
        raise Error("m1.3 thread spike: " + String(failed) + " check(s) failed")
