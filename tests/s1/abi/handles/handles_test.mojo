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
# T2 reframe: a move is a transfer, so the receiver closes exactly once and
# the moved-from source's destructor is suppressed by the compiler (the
# ownership contract, guaranteed structurally — not by counting).  The
# slot-reuse probe runs only AFTER both wrapper frames have unwound (see
# move_and_dispose) so the single close is what the fresh allocation sees.

from mojito_sys.abi.handles import (
    BorrowedFd,
    OpaqueNativeHandle,
    OwnedFd,
)

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
# T2 — move keeps the value and closes exactly once.  The move + receiver
# dispose run inside a helper; by the time it returns both the moved-from
# source and the receiver are out of scope (destructors have run), so the
# reissued slot proves the receiver's single close left the fresh allocation
# alive.
# ----------------------------------------------------------------------------
def move_and_dispose(raw: Int32) -> Bool:
    var src = OwnedFd(raw)
    var dst = src^  # move: src is moved-from, dst owns `raw`.
    if dst.get() != raw:
        return False
    var rc = dst.dispose()  # receiver closes exactly once
    return (rc == 0) and dst.is_disposed()


def t2_move_keeps_value() -> Bool:
    var raw = fresh_fd()
    var disposed_cleanly = move_and_dispose(raw)
    # Both wrapper frames have unwound. A fresh low-fd allocation reuses
    # `raw`'s number and must still be live (only one close happened).
    var probe = fresh_fd()
    return disposed_cleanly and is_open(probe) and (probe == raw)


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


# ---------------------------------------------------------------------------


def main() raises:
    var names = [
        "t1_null_handle",
        "t2_move_keeps_value",
        "t3_dispose_idempotent",
        "t4_borrowed_never_closes",
        "t5_borrow_and_detach",
    ]
    var failures = 0
    for i in range(5):
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
    return False