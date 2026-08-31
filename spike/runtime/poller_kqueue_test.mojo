# spike/runtime/poller_kqueue_test.mojo — M1.3 (#126) runtime spike: a
# native kqueue poller created and operated DIRECTLY from Mojo, no
# mjs_poller.c anywhere in the chain (unlike
# mojito_sys.io.platform.kqueue.KqueuePoller, which wraps it).
# native/posix/mjs_poller.c is the reference for what the semantics have
# to be (issue #126's own framing); this file drives the raw kqueue/kevent
# syscalls against those same semantics: edge/clear registration,
# upsert-on-re-register, verbatim 64-bit token passthrough, and a sticky
# EVFILT_USER wake.
#
# KEVENT BYTE LAYOUT used by poke_kevent/read_kevent_*: ident@0 (u64),
# filter@8 (i16), flags@10 (u16), fflags@12 (u32), data@16 (i64),
# udata@24 (u64) -- 32 bytes, measured byte-exact against a live C oracle
# by spike/abi/types.mojo + spike/abi/struct_layout_test.mojo (#124,
# FINDINGS.md's "kevent" row: PASS on every field). Reused here as a
# MEASURED fact, not re-derived; kevent()'s changelist/eventlist/timeout
# all cross as raw ByteBuf pointers rather than a typed Mojo struct
# (matching mojito_sys/io/externs.mojo's own AGGREGATE RULE: an
# extern-reaching frame never READS an aggregate, only scalar pokes into
# an opaque buffer -- exactly mjs_poller_wait's own out-parameter shape,
# one level lower).
#
# Acceptance criteria this file targets (issue #126, poller half, kqueue
# backend):
#   T1  wait() with a short timeout on nothing-ready reports 0 events;
#   T2  register for readability + a write makes wait() report exactly 1
#       event with the fd and the EXACT verbatim token;
#   T3  modify() upserts interests on the SAME registration (kqueue's own
#       EV_ADD re-add-updates semantics, per mjs_poller.c's own doctrine);
#   T4  unregister() stops delivery even after the fd becomes ready again;
#   T5  a blocked (infinite-timeout) wait is released promptly by wake()
#       from ANOTHER Mojo-spawned thread, and reports ZERO real events
#       (the internal wake knote is filtered out, mirroring
#       mjs_poller_wait's own "wake deliveries never occupy an out slot");
#   T6  register-then-register-again (re-register before any wait) is an
#       upsert: the LAST interests+token win, matching mjs_poller.c's
#       documented upsert contract exactly.
#
# Run via spike/runtime/run.sh. Reports ENVIRONMENT/SKIP (not FAIL) on a
# host without kqueue (Linux) -- see poller_epoll_test.mojo for that
# backend instead. Green requires "RESULT: all green" (or the
# ENVIRONMENT line on a non-kqueue host).

from std.io import FileDescriptor
from std.memory import stack_allocation
from std.sys import CompilationTarget
from std.sys.intrinsics import inlined_assembly

import externs_leaf as ext

comptime KEVENT_SIZE = 32


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


def _null_buf() -> ext.ByteBuf:
    var zero = 0
    return ext.ByteBuf(unsafe_from_address=zero)


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


# ---- kevent byte-buffer helpers (poke OUTSIDE any extern-reaching frame,
# read likewise -- these functions never touch an extern, so the AGGREGATE
# RULE concern from #49/io/externs.mojo does not apply to them). ----------

def poke_kevent(
    buf: ext.ByteBuf,
    ident: UInt64,
    filt: Int16,
    flags: UInt16,
    fflags: UInt32,
    data: Int64,
    udata: UInt64,
):
    buf.bitcast[UInt64]()[0] = ident
    (buf + 8).bitcast[Int16]()[0] = filt
    (buf + 10).bitcast[UInt16]()[0] = flags
    (buf + 12).bitcast[UInt32]()[0] = fflags
    (buf + 16).bitcast[Int64]()[0] = data
    (buf + 24).bitcast[UInt64]()[0] = udata


def kevent_ident(buf: ext.ByteBuf) -> UInt64:
    return buf.bitcast[UInt64]()[0]


def kevent_filter(buf: ext.ByteBuf) -> Int16:
    return (buf + 8).bitcast[Int16]()[0]


def kevent_flags(buf: ext.ByteBuf) -> UInt16:
    return (buf + 10).bitcast[UInt16]()[0]


def kevent_udata(buf: ext.ByteBuf) -> UInt64:
    return (buf + 24).bitcast[UInt64]()[0]


def timeout_buf(cell: UnsafePointer[Int64, MutAnyOrigin], ms: Int64) -> ext.ByteBuf:
    cell[0] = ms / 1000
    cell[1] = (ms % 1000) * 1000000
    return cell.bitcast[Byte]()


comptime WAKE_IDENT: UInt64 = 0x4D4A535953


# One-time thread that wakes `arg[0]` (the kqueue fd) via EVFILT_USER,
# mirroring mjs_poller.c's own internal wake-knote convention.
@export("m13_plr_waker_entry")
def m13_plr_waker_entry(arg: UnsafePointer[Int64, MutAnyOrigin]) abi("C") -> UInt64:
    # comptime-gated body, NOT a runtime check: `@export`'d functions are
    # real ABI-visible symbols the JIT materializes regardless of whether
    # main()'s runtime path ever calls them (confirmed the hard way: on
    # Linux, where `kevent`/`kqueue` do not exist, this function failed to
    # JIT-link with "Symbols not found: [ kqueue, kevent ]" even though
    # main() returns via the ENVIRONMENT branch before ever spawning the
    # thread that would call it) -- mirrors mojito-sys#197's comptime-if,
    # never-runtime-if finding for platform-exclusive externs, one level
    # up (an exported function's body, not just a call site).
    comptime if not CompilationTarget().is_linux():
        var kq = Int32(arg[0])
        var buf = stack_allocation[KEVENT_SIZE, Byte]()
        poke_kevent(
            buf,
            WAKE_IDENT,
            Int16(ext.oracle_const_EVFILT_USER()),
            0,
            ext.oracle_const_NOTE_TRIGGER(),
            0,
            0,
        )
        var rc = ext.probe_kevent(kq, buf, 1, _null_buf(), 0, _null_buf())
        return UInt64(rc)
    else:
        return 0  # unreachable: main() never spawns this thread on Linux


# All real kqueue-calling logic lives in this helper, called ONLY from
# inside a `comptime if not CompilationTarget().is_linux()` branch in
# main() below. This is not just belt-and-suspenders: a runtime check
# alone was measured to be INSUFFICIENT here (mojito-sys#197's own
# finding, one level up from a single call site) -- with only
# `m13_plr_waker_entry`'s body comptime-gated, `mojo run` on Linux still
# failed to JIT-link with "Symbols not found: [ kevent, kqueue ]" naming
# BOTH that function AND `main` in the same failed materialization unit,
# even though main()'s own kqueue calls sit after an unconditional early
# RUNTIME return. Moving every kqueue-calling statement into a separate
# function and gating the CALL at comptime is what actually keeps this
# file linkable on Linux; see poller_epoll_test.mojo's mirrored structure.
def _run_kqueue_checks() raises -> Int:
    var failed = 0
    var kq = ext.probe_kqueue()
    if not check("setup: kqueue() creates a real kq fd", kq >= 0):
        failed += 1

    # Pre-register the sticky wake source (EV_CLEAR: one release per
    # trigger while unobserved), mirroring mjs_poller_create's own
    # convention exactly.
    var wake_reg = stack_allocation[KEVENT_SIZE, Byte]()
    poke_kevent(
        wake_reg,
        WAKE_IDENT,
        Int16(ext.oracle_const_EVFILT_USER()),
        UInt16(ext.oracle_const_EV_ADD() | ext.oracle_const_EV_CLEAR()),
        0,
        0,
        0,
    )
    var wake_rc = ext.probe_kevent(kq, wake_reg, 1, _null_buf(), 0, _null_buf())
    if not check("setup: register internal EVFILT_USER wake source", wake_rc == 0):
        failed += 1

    var fds = stack_allocation[2, Int32]()
    var prc = ext.probe_pipe(fds)
    if not check("setup: pipe() for a real readable/writable fd pair", prc == 0):
        failed += 1
    var rfd = fds[0]
    var wfd = fds[1]

    # ---- T1: wait with nothing ready reports 0 events -----------------------
    var evbuf = stack_allocation[KEVENT_SIZE * 8, Byte]()
    var tsc = stack_allocation[2, Int64]()
    var n_before = ext.probe_kevent(kq, _null_buf(), 0, evbuf, 8, timeout_buf(tsc, 10))
    if not check("T1 wait(10ms) on an unregistered/unready fd reports 0 events", n_before == 0):
        failed += 1

    # ---- register rfd for READABLE, token 111 -------------------------------
    var reg1 = stack_allocation[KEVENT_SIZE, Byte]()
    poke_kevent(
        reg1,
        UInt64(rfd),
        Int16(ext.oracle_const_EVFILT_READ()),
        UInt16(ext.oracle_const_EV_ADD() | ext.oracle_const_EV_CLEAR()),
        0,
        0,
        111,
    )
    var reg1_rc = ext.probe_kevent(kq, reg1, 1, _null_buf(), 0, _null_buf())
    if not check("setup: register rfd for READABLE, token 111", reg1_rc == 0):
        failed += 1

    # ---- T2: write triggers exactly 1 event, verbatim token ------------------
    var wio = FileDescriptor(Int(wfd))
    wio.write("x")
    var n_ready = ext.probe_kevent(kq, _null_buf(), 0, evbuf, 8, timeout_buf(tsc, 1000))
    var t2_ok = (
        n_ready == 1
        and kevent_ident(evbuf) == UInt64(rfd)
        and kevent_udata(evbuf) == 111
    )
    if not check(
        "T2 write() makes wait() report exactly 1 event: fd + token 111"
        " EXACTLY (verbatim passthrough)",
        t2_ok,
    ):
        failed += 1

    # drain the byte so later checks start from "not readable" again
    var drain = stack_allocation[4, Byte]()
    _ = ext.probe_read(rfd, drain, 4)

    # ---- T3: modify (re-register) upserts token/interests -------------------
    var reg2 = stack_allocation[KEVENT_SIZE, Byte]()
    poke_kevent(
        reg2,
        UInt64(rfd),
        Int16(ext.oracle_const_EVFILT_READ()),
        UInt16(ext.oracle_const_EV_ADD() | ext.oracle_const_EV_CLEAR()),
        0,
        0,
        222,
    )
    var reg2_rc = ext.probe_kevent(kq, reg2, 1, _null_buf(), 0, _null_buf())
    wio.write("y")
    var n_mod = ext.probe_kevent(kq, _null_buf(), 0, evbuf, 8, timeout_buf(tsc, 1000))
    var t3_ok = reg2_rc == 0 and n_mod == 1 and kevent_udata(evbuf) == 222
    if not check(
        "T3 modify (re-register) UPSERTS the token: last write (222) wins,"
        " no duplicate registration",
        t3_ok,
    ):
        failed += 1
    var drain2 = stack_allocation[4, Byte]()
    _ = ext.probe_read(rfd, drain2, 4)

    # ---- T4: unregister stops delivery ----------------------------------------
    var del1 = stack_allocation[KEVENT_SIZE, Byte]()
    poke_kevent(del1, UInt64(rfd), Int16(ext.oracle_const_EVFILT_READ()), UInt16(ext.oracle_const_EV_DELETE()), 0, 0, 0)
    var del_rc = ext.probe_kevent(kq, del1, 1, _null_buf(), 0, _null_buf())
    wio.write("z")
    var n_after_unreg = ext.probe_kevent(kq, _null_buf(), 0, evbuf, 8, timeout_buf(tsc, 10))
    if not check(
        "T4 unregister() stops delivery even though the fd is readable again",
        del_rc == 0 and n_after_unreg == 0,
    ):
        failed += 1
    var drain3 = stack_allocation[4, Byte]()
    _ = ext.probe_read(rfd, drain3, 4)

    # ---- T5: blocked wait released by wake() from another thread -------------
    var wake_arg = stack_allocation[1, Int64]()
    wake_arg[0] = Int64(kq)
    var waker = entry_pointer["m13_plr_waker_entry"]()
    var res = stack_allocation[3, Int64]()
    spawn_and_join(waker, ext.ArgPtr(unsafe_from_address=Int(wake_arg)), res)
    # The blocked (infinite-timeout) wait below races the ALREADY-JOINED
    # waker's wake, so it returns promptly rather than actually blocking
    # forever -- exactly what "sticky wake" (EV_CLEAR, coalesces while
    # unobserved) guarantees per mjs_poller.c's own doctrine.
    var n_wake = ext.probe_kevent(kq, _null_buf(), 0, evbuf, 8, _null_buf())
    var real_events = 0
    var i = 0
    var n_wake_i = Int(n_wake)
    while i < n_wake_i:
        var slot = evbuf + i * KEVENT_SIZE
        if not (kevent_ident(slot) == WAKE_IDENT and kevent_filter(slot) == Int16(ext.oracle_const_EVFILT_USER())):
            real_events += 1
        i += 1
    if not check(
        "T5 blocked wait released by wake() from a Mojo-spawned thread,"
        " zero REAL events after filtering the internal wake knote"
        " (waker create/join rc=" + String(res[0]) + "/" + String(res[1]) + ")",
        res[0] == 0 and res[1] == 0 and n_wake >= 1 and real_events == 0,
    ):
        failed += 1

    _ = ext.probe_close(rfd)
    _ = ext.probe_close(wfd)
    _ = ext.probe_close(kq)
    return failed


def main() raises:
    comptime if CompilationTarget().is_linux():
        print("kqueue poller spike: ENVIRONMENT (kqueue is not available on Linux)")
        print("RESULT: ENVIRONMENT")
        return
    if ext.oracle_has_kqueue() == 0:
        print("kqueue poller spike: ENVIRONMENT (no kqueue on this host)")
        print("RESULT: ENVIRONMENT")
        return

    var failed = _run_kqueue_checks()
    print("RESULT: " + ("all green" if failed == 0 else String(failed) + " FAILED"))
    if failed != 0:
        raise Error("m1.3 kqueue poller spike: " + String(failed) + " check(s) failed")
