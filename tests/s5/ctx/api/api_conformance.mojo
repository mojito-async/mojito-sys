# mojito-sys S5.4 — NativeContext Mojo API conformance (issue #67, spec §20).
#
# Drives the mojito_sys/ctx NativeContext surface — a PURE Mojo wrapper over
# the frozen ms_context_* C ABI (zero new C symbols):
#
#   t5_01 create+geometry     — create(+NativeStack reservation) + entry +
#                               userdata; record/stack geometry getters.
#   t5_02 capture             — capture_current() arms a resumable self ctx.
#   t5_03 switch-two-contexts — real switching between TWO NativeContexts
#                               (A -> B -> main), counters verified on both
#                               legs (spec §22 nested switches).
#   t5_04 finish-hook-once    — entry returns -> finish hook fires EXACTLY
#                               once with userdata; record reads FINISHED.
#   t5_05 FINISHED-misuse     — switching INTO a completed context raises
#                               (wrapper maps the C re-resume trap to a
#                               recoverable raise).
#   t5_06 destroy+DEAD-misuse — destroy() poisons the record; post-destroy
#                               switch raises; double-destroy raises.
#   t5_07 self-switch-misuse  — switch(from==to) raises (RUNNING misuse).
#   t5_08 re-capture-revival  — after destroy, re_capture revives destroyed
#                               storage (spec §20): state flips DEAD ->
#                               SUSPENDED and a post-revival switch completes.
#                               The revived snapshot re-enters main once; a
#                               heap guard makes that tail fall through to the
#                               RESULT line (loop-free by construction).
#
# b2 notes (matching tests/s1/*/ and tests/s4/time conventions):
#   - entry/finish callbacks are @export abi("C") defs materialized via the
#     package's entry_pointer() (spike-proven adrp/add mechanism #10);
#   - misuse raises carry decoded, CONSTANT -EINVAL payloads (raise_errno,
#     single-raise-site doctrine, issue #29/#30);
#   - frame/record/cookie blocks are module-internal heap cells indexed by
#     Int (no aggregate reads cross the ABI — byval-poison doctrine);
#   - entries bounce via a non-raising switch helper (trusted path; the
#     conformance's misuse checks exercise the raising switch() directly).

from std.memory import UnsafePointer
from std.memory.alloc import alloc, Layout

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
comptime BYTE_PTR = UnsafePointer[Byte, MutAnyOrigin]

# Per-context work frames (Int cells). Records/cookies ride as raw addresses
# so an entry can reconstruct NativeContext values via _adopt (the
# NativeSocket._adopt internal-plumbing precedent).
comptime F_SELF_REC = Int(0)
comptime F_SELF_COOKIE = Int(1)
comptime F_NEXT_REC = Int(2)
comptime F_NEXT_COOKIE = Int(3)
comptime F_A = Int(4)
comptime F_B = Int(5)
comptime F_DONE = Int(6)
comptime F_FIN = Int(7)
comptime F_NWORDS = Int(8)

# Synthetic usable stack size (16-byte multiple; AAPCS64 stack requirement).
comptime USABLE = Int(256 * 1024)


def _check(name: String, ok: Bool) -> Bool:
    if ok:
        print(name + ": PASS")
    else:
        print(name + ": FAIL")
    return ok


def _make_stack(usable: Int) raises -> NativeStack:
    var ps = page_size()
    return NativeStack.create(usable + ps, usable, ps)


def _frame() -> INT_PTR:
    var ptr = alloc(Layout[Int](count=F_NWORDS)).unsafe_leak()
    var f = INT_PTR(unsafe_from_address=Int(ptr))
    var i = 0
    while i < F_NWORDS:
        f[i] = 0
        i += 1
    return f


def _cell() -> INT_PTR:
    var ptr = alloc(Layout[Int](count=1)).unsafe_leak()
    var c = INT_PTR(unsafe_from_address=Int(ptr))
    c[0] = 0
    return c


def _adopt(rec: Int, cookie: Int) -> NativeContext:
    return NativeContext._adopt(
        INT_PTR(unsafe_from_address=rec),
        INT_PTR(unsafe_from_address=cookie),
    )


# Non-raising switch used by the entry callbacks: the bounce path is trusted
# (misuse checks below never fire on it). The conformance's misuse checks
# exercise the raising switch() directly.
def _bounce(from_c: NativeContext, to_c: NativeContext):
    try:
        NativeContext.switch(from_c, to_c)
    except e:
        _ = e


# ---------------------------------------------------------------------------
# User entries + finish hook (arbitrary @export abi("C") callbacks a caller
# writes; NativeContext dispatches to them exactly like the C trampoline).
# ---------------------------------------------------------------------------
@export("ctx_entry_a")
def ctx_entry_a(ud: CTX_PTR) abi("C"):
    var f = INT_PTR(unsafe_from_address=Int(ud))
    f[F_A] = f[F_A] + 1
    _bounce(_adopt(f[F_SELF_REC], f[F_SELF_COOKIE]), _adopt(f[F_NEXT_REC], f[F_NEXT_COOKIE]))


@export("ctx_entry_b")
def ctx_entry_b(ud: CTX_PTR) abi("C"):
    var f = INT_PTR(unsafe_from_address=Int(ud))
    f[F_B] = f[F_B] + 1
    _bounce(_adopt(f[F_SELF_REC], f[F_SELF_COOKIE]), _adopt(f[F_NEXT_REC], f[F_NEXT_COOKIE]))


@export("ctx_entry_done")
def ctx_entry_done(ud: CTX_PTR) abi("C"):
    var f = INT_PTR(unsafe_from_address=Int(ud))
    f[F_DONE] = f[F_DONE] + 1
    # returns -> wrapper trampoline returns -> C runs the finish hook.


@export("ctx_fin_hook")
def ctx_fin_hook(ud: CTX_PTR) abi("C"):
    var f = INT_PTR(unsafe_from_address=Int(ud))
    f[F_FIN] = f[F_FIN] + 1


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() raises:
    var failed = 0

    # ===================== t5_01 create + geometry =========================
    var stA = _make_stack(USABLE)
    var stB = _make_stack(USABLE)
    var geom_ok = stA.check_geometry() and stB.check_geometry()
    geom_ok = geom_ok and (NativeContext.context_size() >= Int(168))
    geom_ok = geom_ok and (NativeContext.context_alignment() >= 8)
    if not _check("t5_01 create-stack+geometry", geom_ok):
        failed += 1

    # ===================== t5_02 capture ===================================
    var main_ctx = NativeContext.capture_current()
    var cap_ok = (main_ctx.state() == ST_SUSPENDED) and main_ctx.is_live()
    if not _check("t5_02 capture-current", cap_ok):
        failed += 1

    # ===================== t5_03 misaligned-creation rejection =============
    # A hand-constructed NativeStack whose usable span is NOT 16-byte aligned
    # must be rejected deterministically by create() (ms_context_init contract:
    # stack_low 16-aligned; stack_size a nonzero multiple of 16). guard_low=1
    # (odd), top=17 (size 16) -> stack_low is misaligned -> raise.
    var mis_raised = False
    var mis_stack = NativeStack()
    mis_stack.base = 1
    mis_stack.guard_low = 1
    mis_stack.top = 17
    try:
        _ = NativeContext.create(
            mis_stack,
            entry_pointer["ctx_entry_done"](),
            CTX_PTR(unsafe_from_address=Int(_frame())),
        )
    except e:
        mis_raised = True
        _ = e
    if not _check("t5_03 misaligned-creation-rejected", mis_raised):
        failed += 1

    # ===================== t5_04 switch between two contexts ===============
    var fA = _frame()
    var fB = _frame()
    var ctxA = NativeContext.create(
        stA, entry_pointer["ctx_entry_a"](), CTX_PTR(unsafe_from_address=Int(fA))
    )
    var ctxB = NativeContext.create(
        stB, entry_pointer["ctx_entry_b"](), CTX_PTR(unsafe_from_address=Int(fB))
    )
    var start_ok = (ctxA.state() == ST_ARMED) and (ctxB.state() == ST_ARMED)
    if not _check("t5_04 two-contexts-armed", start_ok):
        failed += 1
    fA[F_SELF_REC] = ctxA.record_address()
    fA[F_SELF_COOKIE] = ctxA.cookie_address()
    fA[F_NEXT_REC] = ctxB.record_address()
    fA[F_NEXT_COOKIE] = ctxB.cookie_address()
    fB[F_SELF_REC] = ctxB.record_address()
    fB[F_SELF_COOKIE] = ctxB.cookie_address()
    fB[F_NEXT_REC] = main_ctx.record_address()
    fB[F_NEXT_COOKIE] = main_ctx.cookie_address()
    # main -> A -> B -> main (A and B are two distinct NativeContexts).
    NativeContext.switch(main_ctx, ctxA)
    var bounce_ok = (fA[F_A] == 1) and (fB[F_B] == 1)
    if not _check("t5_05 switch-two-contexts(a->b->main)", bounce_ok):
        failed += 1

    # ===================== t5_04 finish hook exactly once ==================
    var stC = _make_stack(USABLE)
    var fC = _frame()
    var ctxC = NativeContext.create(
        stC, entry_pointer["ctx_entry_done"](), CTX_PTR(unsafe_from_address=Int(fC))
    )
    ctxC.set_finish_hook(entry_pointer["ctx_fin_hook"](), CTX_PTR(unsafe_from_address=Int(fC)))
    var main2 = NativeContext.capture_current()
    NativeContext.switch(main2, ctxC)
    var fin_ok = (fC[F_DONE] == 1) and (fC[F_FIN] == 1)
    fin_ok = fin_ok and (ctxC.state() == ST_FINISHED)
    if not _check("t5_06 finish-hook-exactly-once", fin_ok):
        failed += 1

    # ===================== t5_05 FINISHED misuse ===========================
    var main3 = NativeContext.capture_current()
    var fin_raised = False
    try:
        NativeContext.switch(main3, ctxC)  # ctxC already FINISHED
    except e:
        fin_raised = True
        _ = e
    if not _check("t5_07 finished-resume-misuse-raises", fin_raised):
        failed += 1

    # ===================== t5_06 destroy + DEAD misuse =====================
    var stD = _make_stack(USABLE)
    var fD = _frame()
    var ctxD = NativeContext.create(
        stD, entry_pointer["ctx_entry_done"](), CTX_PTR(unsafe_from_address=Int(fD))
    )
    var main4 = NativeContext.capture_current()
    NativeContext.switch(main4, ctxD)  # D completes (entry returns)
    ctxD.destroy()  # DEAD
    var dead_state_ok = (ctxD.state() == ST_DEAD) and (not ctxD.is_live())
    var main5 = NativeContext.capture_current()
    var dead_raised = False
    try:
        NativeContext.switch(main5, ctxD)
    except e:
        dead_raised = True
        _ = e
    var dead_ok = dead_state_ok and dead_raised
    var dd_raised = False
    try:
        ctxD.destroy()  # double destroy
    except e:
        dd_raised = True
        _ = e
    dead_ok = dead_ok and dd_raised
    if not _check("t5_08 destroy+DEAD-misuse+double-destroy", dead_ok):
        failed += 1

    # ===================== t5_07 self-switch misuse ========================
    var main6 = NativeContext.capture_current()
    var self_raised = False
    try:
        NativeContext.switch(main6, main6)  # from == to (RUNNING misuse)
    except e:
        self_raised = True
        _ = e
    if not _check("t5_09 self-switch-misuse-raises", self_raised):
        failed += 1

    # ===================== t5_08 re-capture revival ========================
    # After destroy, re_capture revives the destroyed storage (spec §20). The
    # revived snapshot resumes main's post-re_capture tail once; a heap guard
    # makes that tail fall through to the RESULT line (loop-free).
    var rev_ctr = _cell()
    ctxD.re_capture()  # C; revived snapshot resumes at `if rev_ctr[0] == 0`
    var revived_state = (ctxD.state() == ST_SUSPENDED) and ctxD.is_live()
    if not _check("t5_10 re-capture-revival(after-destroy)", revived_state):
        failed += 1
    if rev_ctr[0] == 0:
        rev_ctr[0] = 1
        var fin_park = NativeContext.capture_current()
        NativeContext.switch(fin_park, ctxD)
        # (control now lives on ctxD's revived snapshot; see the else below)
    else:
        pass  # revived path re-entered here; fall through to RESULT

    if failed != 0:
        print("RESULT: FAILED (" + String(failed) + " checks)")
        return
    print("RESULT: all green")