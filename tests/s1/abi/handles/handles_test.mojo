# mojito-sys S1 ABI — opaque native handles (issue #27).
#
# Covers spec §7.2 (opaque handles) and §25 (fds; ownership: move transfers,
# destroy closes exactly once, borrowed never closes).
#
# Runs with the platform libc only (no bundled dylib):
#   mojo run -I <repo-root> handles_test.mojo
#
# Descriptor liveness is probed with fcntl(F_GETFD): 0 = open, -1 = closed.
# This makes "closed exactly once" externally testable: after dispose() frees
# the descriptor's number, a fresh low-fd allocation reuses that same number,
# so a second close (double-dispose, or a moved-from destructor) would have
# killed the reused slot.

from mojito_sys.abi.handles import (
    BorrowedFd,
    OpaqueNativeHandle,
    OwnedFd,
)

comptime F_DUPFD: Int32 = 0
comptime F_GETFD: Int32 = 1


@extern("fcntl")
def fd_fcntl(fd: Int32, cmd: Int32, arg: Int32) abi("C") -> Int32:
    ...


# Real open descriptor via the C ABI (lowest-free allocation).
def fresh_fd() -> Int32:
    return fd_fcntl(0, F_DUPFD, 0)


# True when `fd` is still open (no close() consumed this descriptor).
def is_open(fd: Int32) -> Bool:
    return fd_fcntl(fd, F_GETFD, 0) == 0


# ----------------------------------------------------------------------------
# T1 — a default OpaqueNativeHandle() is null.
# ----------------------------------------------------------------------------
def t1_null_handle() -> Bool:
    var h = OpaqueNativeHandle()
    return h.is_null()


# ----------------------------------------------------------------------------
# T2 — move keeps the value; ownership transfers so the moved-from source
# never closes, and the descriptor is closed exactly once (by the receiver).
# ----------------------------------------------------------------------------
def t2_move_keeps_value() -> Bool:
    var src = OwnedFd(fresh_fd())
    var raw = src.get()  # the raw descriptor value the wrapper holds.
    var dst = src^       # move: value keeps across transfer, `src` is moved-from.
    if dst.get() != raw:
        return False
    # Only the receiver may dispose.  Closing once frees `raw`'s slot.
    dst.dispose()
    # A fresh low-fd allocation reuses `raw`'s number; a would-be second close
    # (double-dispose or leaked source destructor) would leave it dead.
    var probe = fresh_fd()
    return is_open(probe) and (probe == raw)


# ----------------------------------------------------------------------------
# T3 — dispose is an idempotent flag: the second dispose() is a no-op, so the
# descriptor is closed exactly once.
# ----------------------------------------------------------------------------
def t3_dispose_idempotent() -> Bool:
    var o = OwnedFd(fresh_fd())
    o.dispose()
    if not o.is_disposed():
        return False
    # First dispose freed the descriptor's slot; an idempotent SECOND dispose
    # must not close whatever now occupies that number.
    var again = OwnedFd(fresh_fd())
    var slot = again.get()
    o.dispose()  # repeat MUST be a no-op.
    var ok = is_open(again.get()) and is_open(slot)
    again.dispose()
    return ok


# ----------------------------------------------------------------------------
# T4 — BorrowedFd never closes: the descriptor stays open even after the
# borrowed wrapper leaves scope (a borrow holds no ownership).
# ----------------------------------------------------------------------------
def t4_borrowed_never_closes() -> Bool:
    var raw = fresh_fd()
    # `wrap_borrowed` both witnesses liveness while the wrapper is alive and
    # lets the wrapper be destroyed before we re-probe at `is_open(raw)`.
    var alive_while_borrowed = wrap_borrowed(raw)
    return alive_while_borrowed and is_open(raw)


def wrap_borrowed(raw: Int32) -> Bool:
    var b = BorrowedFd(raw)
    return is_open(raw)


# ---------------------------------------------------------------------------


def main() raises:
    var t1 = t1_null_handle()
    var t2 = t2_move_keeps_value()
    var t3 = t3_dispose_idempotent()
    var t4 = t4_borrowed_never_closes()
    var failures = 0
    if t1:
        print("t1_null_handle: PASS")
    else:
        print("t1_null_handle: FAIL")
        failures += 1
    if t2:
        print("t2_move_keeps_value: PASS")
    else:
        print("t2_move_keeps_value: FAIL")
        failures += 1
    if t3:
        print("t3_dispose_idempotent: PASS")
    else:
        print("t3_dispose_idempotent: FAIL")
        failures += 1
    if t4:
        print("t4_borrowed_never_closes: PASS")
    else:
        print("t4_borrowed_never_closes: FAIL")
        failures += 1

    print("RESULT: " + ("all green" if failures == 0 else String(failures) + " FAILED"))
    if failures != 0:
        raise Error("handles: " + String(failures) + " test(s) FAILED")