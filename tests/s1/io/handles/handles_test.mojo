# mojito-sys S6.1/S1 — io handle home: NativeIoHandle (#73) + fd ownership
# wrappers (#42).
#
# Covers spec §27.1 (register(handle, ...) consumes NativeIoHandle), the
# §25 ownership semantics of the io wrapper family (move transfers,
# destruction closes exactly once, borrowed never closes, moved-from
# detectable in debug), and the §4 placement: OwnedFd / BorrowedFd live in
# mojito_sys.io.handle — the abi/ path is gone for them.
#
# Runs with the platform libc only (no bundled dylib):
#   mojo run -I <repo-root> handles_test.mojo
#
# Descriptor liveness is probed with fcntl(F_GETFD): a descriptor is open
# when the call returns >= 0 (-1 = no such fd).  Slots are high and FIXED
# per test (101..): the suite is single-threaded and owns nothing below
# 100, and re-duping a slot onto stdin's copy is what lets us prove
# "closed exactly once" (a stale second close would kill the reissued
# slot).  Do not parallelize these checks.

from mojito_sys.io.handle import (
    BorrowedFd,
    NativeIoHandle,
    NO_FD,
    OwnedFd,
    ms_close,
)

comptime F_GETFD: Int32 = 1

# Probe descriptor slots are HIGH and FIXED per test (101..): the suite is
# single-threaded and owns nothing below 100, so lowest-free-slot reuse
# tricks are unnecessary here.
comptime T1_SLOT: Int32 = 101
comptime T2_SLOT: Int32 = 102
comptime T3_SLOT: Int32 = 103
comptime T4_SLOT: Int32 = 104
comptime T5A_SLOT: Int32 = 105
comptime T5B_SLOT: Int32 = 106
comptime T6_SLOT: Int32 = 107
comptime T7_SLOT: Int32 = 108
comptime T8_SLOT: Int32 = 109


@extern("dup2")
def ms_dup2(oldfd: Int32, newfd: Int32) abi("C") -> Int32:
    ...


@extern("fcntl")
def ms_fcntl(fd: Int32, cmd: Int32, arg: Int32) abi("C") -> Int32:
    ...


# A real open descriptor: duplicate stdin onto the caller's fixed high slot.
# Stdin dependency (SYS-5 note): fresh_fd dups fd 0, so it FAILS on
# daemonized runners or environments with closed/redirected stdio
# (EBADF) — the suite requires an open fd 0.
# fcntl(F_DUPFD) is avoided DELIBERATELY: observed mojo 1.0.0b2 miscompiles
# early variadic F_DUPFD call sites (-1 regardless of argument validity)
# depending on surrounding code shape; dup2 is position-independent.
# tracking: F_DUPFD b2 miscompile — re-trial on toolchain bump (see the
# workaround note above; drop dup2 shim if F_DUPFD ever compiles true).
# NOTE: dup2(2) returns NEWFD on success — not 0 — so the success check
# compares against the slot itself.
def fresh_fd(slot: Int32) -> Int32:
    var rc = ms_dup2(0, slot)
    if rc == slot:
        return slot
    return -1


# True when `fd` is currently open (no close() consumed this descriptor).
def is_open(fd: Int32) -> Bool:
    return ms_fcntl(fd, F_GETFD, 0) >= 0


# ----------------------------------------------------------------------------
# T1 — raw-value roundtrip: wrap an open descriptor, read the same raw value
# back; the null/default sentinel is NOT valid.
# ----------------------------------------------------------------------------
def t1_raw_value_roundtrip() -> Bool:
    var raw = fresh_fd(T1_SLOT)
    var h = NativeIoHandle(raw)
    var roundtrip = (h.get() == raw) and h.is_valid()
    var default_invalid = not NativeIoHandle().is_valid()
    var sentinel_invalid = not NativeIoHandle(-1).is_valid()
    _ = ms_close(raw)  # test hygiene: NativeIoHandle never closes.
    return roundtrip and default_invalid and sentinel_invalid


# ----------------------------------------------------------------------------
# T2 — borrow never closes: a non-owning view taken through borrow() lives in
# its own frame and dies there WITHOUT closing the underlying descriptor.
# ----------------------------------------------------------------------------
def borrow_and_drop(raw: Int32) -> Bool:
    var view = NativeIoHandle(raw).borrow()
    return view.get() == raw and is_open(raw)


def t2_borrow_never_closes() -> Bool:
    var raw = fresh_fd(T2_SLOT)
    var alive_in_frame = borrow_and_drop(raw)
    var still_open_after = is_open(raw)
    _ = ms_close(raw)  # test hygiene.
    return alive_in_frame and still_open_after


# ----------------------------------------------------------------------------
# T3 — move transfers, moved-from detectable.  Two flavors of transfer:
#   a) `dst = src^` — the compiler-enforced move: dst keeps the exact raw
#      value (the source is rejected as uninitialized afterwards, which is
#      itself the strongest form of moved-from detection).
#   b) `dst = src.take()` — move-out that leaves the source initialized but
#      invalid: src.is_valid() == False and get() == NO_FD, the
#      debug-detectable sentinel state.
# Neither flavor closes the underlying descriptor.
# ----------------------------------------------------------------------------
def t3_move_transfers_moved_from_detectable() -> Bool:
    var raw = fresh_fd(T3_SLOT)
    var src = NativeIoHandle(raw)
    var moved = src^  # compiler-enforced move: token lands in `moved`.
    var ok_moved = moved.is_valid() and (moved.get() == raw)
    var holder = NativeIoHandle(raw)
    var ok_taken = holder.take().get() == raw
    var ok_src = (not holder.is_valid()) and (holder.get() == NO_FD)
    var no_close_on_move = is_open(raw)
    _ = ms_close(raw)  # test hygiene.
    return ok_moved and ok_taken and ok_src and no_close_on_move


# ----------------------------------------------------------------------------
# T4 — OwnedFd: move keeps the value and closes EXACTLY ONCE, with
# destructor timing OBSERVED.  move_and_dispose closes raw and re-dups its
# slot (fresh copy of stdin onto the same number) while the moved-from
# source is still alive in that frame; if the source destructor were not
# suppressed at unwind, its second close would kill the reissued slot and
# the caller's liveness probe fails.
# ----------------------------------------------------------------------------
def move_and_dispose(raw: Int32) -> Int32:
    var src = OwnedFd(raw)
    var dst = src^  # move: src is moved-from, dst owns `raw`.
    if dst.get() != raw:
        return -1  # value not retained across the move.
    if dst.dispose() != 0:  # receiver closes exactly once.
        return -1
    return fresh_fd(raw)  # reissues raw's slot before src's frame unwinds.


def t4_move_keeps_value_closes_once() -> Bool:
    var raw = fresh_fd(T4_SLOT)
    var probe = move_and_dispose(raw)
    var ok = (probe == raw) and is_open(probe)
    if ok:
        var owner = OwnedFd(probe)
        ok = owner.dispose() == 0
    return ok


# ----------------------------------------------------------------------------
# T5 — dispose is an idempotent flag: the second dispose() is a no-op, so
# the descriptor is closed exactly once.
# ----------------------------------------------------------------------------
def t5_dispose_idempotent() -> Bool:
    var o = OwnedFd(fresh_fd(T5A_SLOT))
    var rc1 = o.dispose()
    if rc1 != 0 or not o.is_disposed():
        return False
    # First dispose freed T5A_SLOT and reset this owner to NO_FD; re-arm it
    # on T5B_SLOT so we can prove the repeat close did NOT touch anything
    # live.
    var again = OwnedFd(fresh_fd(T5B_SLOT))
    var slot = again.get()
    var rc2 = o.dispose()  # repeat MUST be a no-op returning 0.
    var ok = (rc2 == 0) and is_open(again.get()) and is_open(slot)
    _ = again.dispose()
    return ok


# ----------------------------------------------------------------------------
# T6 — BorrowedFd never closes: the descriptor stays open even after the
# borrowed wrapper leaves scope (a borrow holds no ownership).
# ----------------------------------------------------------------------------
def wrap_borrowed(raw: Int32) -> Bool:
    # One call frame: a borrowed wrapper is born and dies here; it carries
    # no ownership, so it must not close anything.
    var _ = BorrowedFd(raw)
    return is_open(raw)


def t6_borrowed_never_closes() -> Bool:
    var raw = fresh_fd(T6_SLOT)
    var alive_while_borrowed = wrap_borrowed(raw)
    var still_open_after = is_open(raw)
    # Now the test itself owns the descriptor: close it once so nothing leaks.
    var owner = OwnedFd(raw)
    var rc = owner.dispose()
    return alive_while_borrowed and still_open_after and (rc == 0)


# ----------------------------------------------------------------------------
# T7 — borrow() is a safe non-owning view; detach() surrenders ownership:
# detach leaves the OwnedFd inert and hands the caller a live fd to close.
# ----------------------------------------------------------------------------
def t7_borrow_and_detach() -> Bool:
    var raw = fresh_fd(T7_SLOT)
    var own = OwnedFd(raw)
    var borrowed = own.borrow()
    if borrowed.get() != raw or borrowed.is_null():
        return False
    var fd_out = own.detach()  # caller takes ownership; `own` becomes inert
    if not own.is_disposed() or not own.is_null():
        return False
    var ok = is_open(fd_out)  # detach did NOT close
    var owner = OwnedFd(fd_out)  # close it once via an owned wrapper
    var rc = owner.dispose()
    return ok and (rc == 0) and (fd_out == raw)


# ----------------------------------------------------------------------------
# T8 — dispose() surfaces the close(2) status.  When the underlying close
# fails (descriptor already closed behind the wrapper's back -> EBADF,
# rc == -1), the monotone flag stays CLEAR and the held fd is UNCHANGED so
# the caller may retry; only rc == 0 commits _disposed/NO_FD.  The fd is
# then detached to make the wrapper inert without a second failing close.
# ----------------------------------------------------------------------------
def t8_dispose_surfaces_error() -> Bool:
    var raw = fresh_fd(T8_SLOT)
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
    var names = [
        "t1_raw_value_roundtrip",
        "t2_borrow_never_closes",
        "t3_move_transfers_moved_from_detectable",
        "t4_move_keeps_value_closes_once",
        "t5_dispose_idempotent",
        "t6_borrowed_never_closes",
        "t7_borrow_and_detach",
        "t8_dispose_surfaces_error",
    ]
    var failures = 0
    for i in range(8):
        var ok = call_test(i + 1)
        print(names[i] + ": " + ("PASS" if ok else "FAIL"))
        if not ok:
            failures += 1
    print("RESULT: " + ("all green" if failures == 0 else String(failures) + " FAILED"))
    if failures != 0:
        raise Error("io-handles: " + String(failures) + " test(s) FAILED")


def call_test(i: Int) -> Bool:
    if i == 1:
        return t1_raw_value_roundtrip()
    elif i == 2:
        return t2_borrow_never_closes()
    elif i == 3:
        return t3_move_transfers_moved_from_detectable()
    elif i == 4:
        return t4_move_keeps_value_closes_once()
    elif i == 5:
        return t5_dispose_idempotent()
    elif i == 6:
        return t6_borrowed_never_closes()
    elif i == 7:
        return t7_borrow_and_detach()
    elif i == 8:
        return t8_dispose_surfaces_error()
    return False
