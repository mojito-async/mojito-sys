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
from mojito_sys.io.handle import NativeIoHandle, NO_FD

comptime F_GETFD: Int32 = 1

# Probe descriptor slots are HIGH and FIXED per test (101..): the suite is
# single-threaded and owns nothing below 100, so lowest-free-slot reuse
# tricks are unnecessary here.
comptime T1_SLOT: Int32 = 101
comptime T2_SLOT: Int32 = 102
comptime T3_SLOT: Int32 = 103


@extern("dup2")
def ms_dup2(oldfd: Int32, newfd: Int32) abi("C") -> Int32:
    ...


@extern("fcntl")
def ms_fcntl(fd: Int32, cmd: Int32, arg: Int32) abi("C") -> Int32:
    ...


# A real open descriptor: duplicate stdin onto the caller's fixed high slot.
# fcntl(F_DUPFD) is avoided DELIBERATELY: observed mojo 1.0.0b2 miscompiles
# early variadic F_DUPFD call sites (-1 regardless of argument validity)
# depending on surrounding code shape; dup2 is position-independent.
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
