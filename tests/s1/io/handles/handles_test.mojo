# mojito-sys S6.1 — io scaffold: NativeIoHandle fd-handle home (issue #73).
#
# Covers spec §27.1 (register(handle, ...) consumes NativeIoHandle) and the
# §25 ownership semantics the io wrapper family carries: move transfers,
# borrow never closes, moved-from state detectable in debug.
#
# Runs with the platform libc only (no bundled dylib):
#   mojo run -I <repo-root> handles_test.mojo
#
# Descriptor liveness is probed with fcntl(F_GETFD): a descriptor is open
# when the call returns >= 0 (-1 = no such fd).  Slot reuse is deterministic
# only under a single-threaded process with few descriptors, which this suite
# assumes and states (same discipline as tests/s1/abi/handles).  Do not
# parallelize these checks.
#
# NOTE(issue #42): until the fd OWNERSHIP wrappers migrate up from
# mojito_sys.abi.handles, this suite borrows the platform close(2) binding
# from there purely for test hygiene; NativeIoHandle itself never closes.

from mojito_sys.abi.handles import ms_close
from mojito_sys.io.handle import NativeIoHandle

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
# T1 — raw-value roundtrip: wrap an open descriptor, read the same raw value
# back; the null/default sentinel is NOT valid.
# ----------------------------------------------------------------------------
def t1_raw_value_roundtrip() -> Bool:
    var raw = fresh_fd()
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
    var raw = fresh_fd()
    var alive_in_frame = borrow_and_drop(raw)
    var still_open_after = is_open(raw)
    _ = ms_close(raw)  # test hygiene.
    return alive_in_frame and still_open_after


# ----------------------------------------------------------------------------
# T3 — move transfers, moved-from detectable: after `dst = src^`, dst keeps
# the exact raw value while src drops to the NO_FD sentinel (is_valid() ==
# False, get() == NO_FD) — the debug-detectable invalid state.  A move of the
# non-owning value type closes nothing.
# ----------------------------------------------------------------------------
def t3_move_transfers_moved_from_detectable() -> Bool:
    var raw = fresh_fd()
    var src = NativeIoHandle(raw)
    var dst = src^  # move: ownership of the token transfers, src is moved-from.
    var ok_dst = dst.is_valid() and (dst.get() == raw)
    var ok_src = (not src.is_valid()) and (src.get() == NativeIoHandle.NO_FD)
    var no_close_on_move = is_open(raw)
    _ = ms_close(raw)  # test hygiene.
    return ok_dst and ok_src and no_close_on_move


# ---------------------------------------------------------------------------


def main() raises:
    var names = [
        "t1_raw_value_roundtrip",
        "t2_borrow_never_closes",
        "t3_move_transfers_moved_from_detectable",
    ]
    var failures = 0
    for i in range(3):
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
    return False
