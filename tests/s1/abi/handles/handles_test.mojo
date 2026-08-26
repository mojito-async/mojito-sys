# mojito-sys S1 ABI — opaque native handles (issue #27).
#
# Covers spec §7.2 (opaque handles) and §25 (fds; ownership: move transfers,
# destroy closes exactly once, borrowed never closes).
#
# Runs with the platform libc only (no bundled dylib):
#   mojo run -I <repo-root> handles_test.mojo
#
# Descriptor liveness is probed with fcntl(F_GETFD): a descriptor is open
# when the call returns >= 0 (-1 = no such fd).  Slot reuse is deterministic
# only under a single-threaded process with few descriptors, which this suite
# assumes and states: the lowest-free slot allocation is what lets us prove
# "closed exactly once" by reissuing the same number after a close and
# re-probing liveness (a stale second close would kill the reissued slot).
# Do not parallelize these checks.
#
# T2 reframe: a move is a transfer, and the probe OBSERVES the moved-from
# source's destructor suppression rather than assuming it.  The helper
# reissues raw's fd slot WHILE the moved-from source is still in scope; if
# the compiler failed to suppress src's destructor at frame unwind, its
# second close would kill that reissued slot and the caller's liveness
# probe fails.

from mojito_sys.abi.handles import (
    BorrowedFd,
    OpaqueNativeHandle,
    OwnedFd,
    ms_close,  # close(2) binding reused for failure injection.
)
from std.memory.unsafe_pointer import UnsafePointer


# ---------------------------------------------------------------------------
# T7 — pointer-origin conformance (issue #45): HandlePtr must remain EXACTLY
# spec §7.2's sketch, UnsafePointer[NoneType, MutUntrackedOrigin].  Origins
# do not implicitly convert in Mojo, so calling assert_spec_origin with a
# HandlePtr compiles only while the alias stays bound to the spec type; a
# rebind to any other origin (e.g. MutAnyOrigin) fails compilation here.
# ---------------------------------------------------------------------------
comptime SpecHandlePtr = UnsafePointer[NoneType, MutUntrackedOrigin]


def assert_spec_origin(p: SpecHandlePtr):
    pass




comptime F_DUPFD: Int32 = 0
comptime F_GETFD: Int32 = 1


@extern("fcntl")
def ms_fcntl(fd: Int32, cmd: Int32, arg: Int32) abi("C") -> Int32:
    ...


# Real open descriptor via the C ABI (lowest-free allocation).
def fresh_fd() -> Int32:
    return ms_fcntl(0, F_DUPFD, 0)


# True when `fd` is currently open (no close() consumed this descriptor).
def is_open(fd: Int32) -> Bool:
    return ms_fcntl(fd, F_GETFD, 0) >= 0


# ----------------------------------------------------------------------------
# T1 — a default OpaqueNativeHandle() is null.
# ----------------------------------------------------------------------------
def t1_null_handle() -> Bool:
    var h = OpaqueNativeHandle()
    return h.is_null()

# ----------------------------------------------------------------------------
# T2 — move keeps the value and closes exactly once, with destructor timing
# OBSERVED.  move_and_dispose closes raw and reissues its slot (fresh low-fd
# allocation) while the moved-from source is still alive in that frame; only
# after both wrappers unwind does the caller probe.  If the source
# destructor were not suppressed it would close again during unwind —
# killing the reissued slot — so a live probe proves suppression happened.
# Returns the reissued descriptor, or -1 on any internal failure.
# ----------------------------------------------------------------------------
def move_and_dispose(raw: Int32) -> Int32:
    var src = OwnedFd(raw)
    var dst = src^  # move: src is moved-from, dst owns `raw`.
    if dst.get() != raw:
        return -1  # value not retained across the move.
    if dst.dispose() != 0:  # receiver closes exactly once.
        return -1
    return fresh_fd()  # reissues raw's number before src's frame unwinds.


def t2_move_keeps_value() -> Bool:
    var raw = fresh_fd()
    var probe = move_and_dispose(raw)
    # Both wrapper frames have unwound. The probe reused raw's number while
    # src was still in scope; it must still be live (the moved-from source's
    # destructor did NOT fire a second close during unwind).
    var ok = (probe == raw) and is_open(probe)
    if ok:
        var owner = OwnedFd(probe)
        ok = owner.dispose() == 0
    return ok


# ----------------------------------------------------------------------------
# T3 — dispose is an idempotent flag: the second dispose() is a no-op, so
# the descriptor is closed exactly once.
# ----------------------------------------------------------------------------
def t3_dispose_idempotent() -> Bool:
    var o = OwnedFd(fresh_fd())
    var rc1 = o.dispose()
    if rc1 != 0 or not o.is_disposed():
        return False
    # First dispose freed the descriptor's slot and reset this owner to NO_FD.
    var again = OwnedFd(fresh_fd())
    var slot = again.get()
    var rc2 = o.dispose()  # repeat MUST be a no-op returning 0.
    var ok = (rc2 == 0) and is_open(again.get()) and is_open(slot)
    _ = again.dispose()
    return ok


# ----------------------------------------------------------------------------
# T4 — BorrowedFd never closes: the descriptor stays open even after the
# borrowed wrapper leaves scope (a borrow holds no ownership).
# ----------------------------------------------------------------------------
def wrap_borrowed(raw: Int32) -> Bool:
    # One call frame: a borrowed wrapper is born and dies here; it carries no
    # ownership, so it must not close anything.
    var _ = BorrowedFd(raw)
    return is_open(raw)


def t4_borrowed_never_closes() -> Bool:
    var raw = fresh_fd()
    var alive_while_borrowed = wrap_borrowed(raw)
    var still_open_after = is_open(raw)
    # Now the test itself owns the descriptor: close it once so nothing leaks.
    var owner = OwnedFd(raw)
    var rc = owner.dispose()
    return alive_while_borrowed and still_open_after and (rc == 0)


# ----------------------------------------------------------------------------
# T5 — borrow() is a safe non-owning view and detach() surrenders ownership:
# detach() leaves the OwnedFd inert and hands the caller a live fd to close.
# ----------------------------------------------------------------------------
def t5_borrow_and_detach() -> Bool:
    var raw = fresh_fd()
    var own = OwnedFd(raw)
    var borrowed = own.borrow()
    if borrowed.get() != raw or borrowed.is_null():
        return False
    var fd_out = own.detach()          # caller takes ownership; `own` becomes inert
    if not own.is_disposed() or not own.is_null():
        return False
    var ok = is_open(fd_out)           # detach did NOT close
    var owner = OwnedFd(fd_out)        # close it once via an owned wrapper
    var rc = owner.dispose()
    return ok and (rc == 0) and (fd_out == raw)


# ----------------------------------------------------------------------------
# T6 — H1: dispose() surfaces the close(2) status.  When the underlying
# close fails (descriptor already closed behind the wrapper's back -> EBADF,
# rc == -1), the monotone flag stays CLEAR and the held fd is UNCHANGED so
# the caller may retry; only rc == 0 commits _disposed/NO_FD.  The fd is
# then detached to make the wrapper inert without a second failing close.
# ----------------------------------------------------------------------------
def t6_dispose_surfaces_error() -> Bool:
    var raw = fresh_fd()
    var own = OwnedFd(raw)
    # Inject the failure: close raw out from under the owner.
    if ms_close(raw) != 0:
        return False
    var rc = own.dispose()  # must surface -1, not swallow it.
    var flag_clear = not own.is_disposed()  # failed close must NOT commit.
    var fd_kept = own.get() == raw  # retryable: fd unchanged.
    var inert = own.detach() == raw  # surrender without another close.
    return (rc == -1) and flag_clear and fd_kept and inert


# ---------------------------------------------------------------------------


def main() raises:
    # T7 — pointer-origin conformance (issue #45): compiles only while
    # HandlePtr stays EXACTLY UnsafePointer[NoneType, MutUntrackedOrigin]
    # (spec §7.2 sketch); origins do not implicitly convert, so a rebind to
    # any other origin (e.g. MutAnyOrigin) fails compilation right here.
    # NOTE: checked inline in main, NOT via call_test — an 8-way call_test
    # dispatch trips a mojo 1.0.0b2 miscompile that flips t2-t6 red.
    var origin_probe = OpaqueNativeHandle()
    assert_spec_origin(origin_probe.pointer())
    print("t7_pointer_origin_matches_spec: PASS")

    var names = [
        "t1_null_handle",
        "t2_move_keeps_value",
        "t3_dispose_idempotent",
        "t4_borrowed_never_closes",
        "t5_borrow_and_detach",
        "t6_dispose_surfaces_error",
    ]
    var failures = 0
    for i in range(6):
        var ok = call_test(i + 1)
        print(names[i] + ": " + ("PASS" if ok else "FAIL"))
        if not ok:
            failures += 1
    print("RESULT: " + ("all green" if failures == 0 else String(failures) + " FAILED"))
    if failures != 0:
        raise Error("handles: " + String(failures) + " test(s) FAILED")


def call_test(i: Int) -> Bool:
    if i == 1:
        return t1_null_handle()
    elif i == 2:
        return t2_move_keeps_value()
    elif i == 3:
        return t3_dispose_idempotent()
    elif i == 4:
        return t4_borrowed_never_closes()
    elif i == 5:
        return t5_borrow_and_detach()
    elif i == 6:
        return t6_dispose_surfaces_error()
    return False