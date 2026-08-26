# mojito-sys S5.4 — NativeContext Mojo API conformance (issue #67, spec §20).
#
# Drives the mojito_sys/ctx NativeContext surface — a PURE Mojo wrapper over
# the frozen ms_context_* C ABI (zero new C symbols).
#
# SCOPE (b2 1.0.0b2 JIT limitation, documented): executing a REAL
# machine-context switch through the b2 JIT deterministically traps the
# production #66 lifecycle on this host (Stack dump in libKGENCompilerRT;
# same crash class the S5.6 bench lane documents — "the b2 JIT
# deterministically traps the production #66 context lifecycle"; it builds
# AOT and runs min-of-N). This conformance therefore validates every
# wrapper behavior reachable WITHOUT executing a switch:
#   - record/cookie geometry + alignment (size 200, alignment 8);
#   - capture_current() arms a SUSPENDED live entry;
#   - create() over a NativeStack reservation arms an entry, and rejects a
#     misaligned span with a decoded raise;
#   - state getters: ST_ARMED after create, ST_SUSPENDED after capture,
#     ST_DEAD + !is_live after destroy;
#   - misuse raises: destroy() on a dead context raises; finish-hook
#     registration accepts/replaces a hook (registry read-back is not
#     exposed, but set_finish_hook never raises on a live context);
#   - re_capture() revives a destroyed record (state SUSPENDED + live).
#
# The real-switch conformance rows (A->B bounce, finish-hook fires once,
# FINISHED/RUNNING misuse raising on switch, re-capture revival by resume)
# are documented-but-red on this toolchain: the C probes under
# tests/s5/ctx/lifecycle/ + stack_probe.c cover those behaviors at the C
# level, and the rows return to this lane when b2's JIT can execute the
# frozen lifecycle.

from std.memory import UnsafePointer

from mojito_sys.ctx import NativeContext, entry_pointer
from mojito_sys.ctx.context import (
    ST_DEAD,
    ST_ARMED,
    ST_FINISHED,
    ST_SUSPENDED,
)
from mojito_sys.memory.stack import NativeStack
from mojito_sys.memory.page import page_size

comptime CTX_PTR = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime INT_PTR = UnsafePointer[Int, MutAnyOrigin]
comptime USABLE = Int(256 * 1024)

@export("user_entry_done")
def user_entry_done(ud: CTX_PTR) abi("C"):
    pass

@export("user_fin_hook")
def user_fin_hook(ud: CTX_PTR) abi("C"):
    pass


def _check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok

def _make_stack(usable: Int) raises -> NativeStack:
    var ps = page_size()
    return NativeStack.create(usable + ps, usable, ps)

def main() raises:
    var failed = 0

    # ---- t6_01 geometry ----------------------------------------------------
    var geom_ok = (NativeContext.context_size() == Int(200))
    geom_ok = geom_ok and (NativeContext.context_alignment() == Int(8))
    if not _check("t6_01 record-geometry-200B-al8", geom_ok):
        failed += 1

    # ---- t6_02 capture_current ---------------------------------------------
    var main_ctx = NativeContext.capture_current()
    var cap_ok = (main_ctx.state() == ST_SUSPENDED)
    cap_ok = cap_ok and main_ctx.is_live()
    if not _check("t6_02 capture-current-suspended-live", cap_ok):
        failed += 1

    # ---- t6_03 create over a real reservation --------------------------------
    var stA = _make_stack(USABLE)
    var stB = _make_stack(USABLE)
    var ctxA = NativeContext.create(
        stA.guard_low,
        stA.top,
        entry_pointer["ctx_entry_done"](),
        CTX_PTR(unsafe_from_address=Int(0)),
    )
    var ctxB = NativeContext.create(
        stB.guard_low,
        stB.top,
        entry_pointer["ctx_entry_done"](),
        CTX_PTR(unsafe_from_address=Int(0)),
    )
    var create_ok = (ctxA.state() == ST_ARMED) and (ctxB.state() == ST_ARMED)
    if not _check("t6_03 create-two-armed", create_ok):
        failed += 1

    # ---- t6_04 misaligned creation rejected ----------------------------------
    var mis_raised = False
    var mis = NativeStack()
    mis.base = 1
    mis.guard_low = 1
    mis.top = 17
    try:
        _ = NativeContext.create(
            mis.guard_low,
            mis.top,
            entry_pointer["user_entry_done"](),
            CTX_PTR(unsafe_from_address=Int(0)),
        )
    except e:
        mis_raised = True
        _ = e
    if not _check("t6_04 misaligned-create-raises", mis_raised):
        failed += 1

    # ---- t6_05 destroy -> DEAD + double-destroy raises ------------------------
    ctxA.destroy()
    var dead_ok = (ctxA.state() == ST_DEAD) and (not ctxA.is_live())
    if not _check("t6_05 destroy-dead-notlive", dead_ok):
        failed += 1
    var dd = False
    try:
        ctxA.destroy()  # already DEAD -> raise
    except e:
        dd = True
        _ = e
    if not _check("t6_06 double-destroy-raises", dd):
        failed += 1

    # ---- t6_07 finish-hook registration (valid ctx -> no raise) ---------------
    var hook_ok = True
    try:
        ctxB.set_finish_hook(
            entry_pointer["user_fin_hook"](),
            CTX_PTR(unsafe_from_address=Int(0)),
        )
    except e:
        hook_ok = False
        _ = e
    if not _check("t6_07 finish-hook-register-ok", hook_ok):
        failed += 1

    # ---- t6_08 re_capture revives a destroyed record --------------------------
    var rc_ok = False
    try:
        ctxA.re_capture()
        rc_ok = (ctxA.state() == ST_SUSPENDED) and ctxA.is_live()
    except e:
        _ = e
    if not _check("t6_08 re-capture-revives", rc_ok):
        failed += 1
    # Re-dead it so the drop path sees the C record in a neutral state (the
    # wrapper frees its own heap blocks regardless).
    try:
        ctxA.destroy()
    except e:
        _ = e

    if failed != 0:
        print("RESULT: FAILED (" + String(failed) + " checks)")
        return
    print("RESULT: all green")
