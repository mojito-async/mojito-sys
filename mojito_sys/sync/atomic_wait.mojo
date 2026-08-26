# mojito-sys S3.3 — atomic wait/wake on u32 words (issue #59, spec §18).
#
# Spec §18 surface bound to the frozen C ABI (native/include/mojito_sys.h,
# s3-atomic-wait block):
#   mjs_atomic_wait_on_u32(addr, expected, deadline_ns)  — BLOCKS;
#   mjs_atomic_wake_one_u32(addr) / mjs_atomic_wake_all_u32(addr).
#
# Backend map: Linux futex (FUTEX_*_PRIVATE); macOS ships the #60
# fallback (hashed NativeMutex+NativeCondVar waiter table inside
# mjs_atomic_wait.c). Windows remains a later issue; on hosts without a
# backend the C layer returns EXACTLY -ENOSYS, so wait_on_u32 raises the
# decoded ENOSYS deterministically (never sleeps) and wake_* surface it
# as a negative return — the backend-parameterized suite detects this
# and runs its unsupported-backend mode.
#
# DOCUMENTED b2 ADAPTATIONS (vs the spec §18 spelling):
#   - The origin parameter ships as `[origin: Origin]` — b2's generic
#     origin bound; `ImmutableOrigin` does not exist in 1.0.0b2.
#   - wake_one_u32/wake_all_u32 are non-raising per the spec signature, so
#     errors travel IN the Int return verbatim from the frozen ABI
#     contract: >= 0 = exact woken count, negative = -errno (including
#     -ENOSYS where no backend exists, -EFAULT for a null address). This
#     divergence is VISIBLE upstream rather than silently swallowed.
#
# STATUS MAPPING (frozen ABI, documented in the header block):
#   0          -> WaitStatus.ok       — woken OR word != expected at sleep
#                                        time (futex EAGAIN folds into ok:
#                                        "re-read the word" either way)
#   -ETIMEDOUT -> WaitStatus.timed_out
#   other      -> raise_errno(rc)     — decoded, host-spelled diagnostic
#
# SPURIOUS WAKEUP CONTRACT (sync/common.mojo): .ok never promises the
# predicate holds. Callers MUST loop: re-check the word after every .ok
# and re-wait while it still reads `expected` (wait_until_changed below is
# the reference shape).
#
# ETIMEDOUT IS HOST-SPELLED: darwin numbers it 60, Linux 110 (like the
# EBUSY/EINVAL constants in sync/mutex.mojo, both spellings are accepted
# so the wrapper decodes identically on either host numbering). ENOSYS is
# likewise dual-spelled (darwin 78 / Linux 38) and exported for backend
# DETECTION by callers and the conformance suite.
#
# b2 conventions (matching mojito_sys/sync/mutex.mojo, issue #57):
#   - @extern bindings + probe shims live in the pure-extern leaf
#     mojito_sys/sync/externs.mojo; this module decodes/raises only AFTER
#     each call has returned.
#   - Out-slots / escaping pointers are UnsafePointer[..., MutAnyOrigin];
#     the deadline cell pointer escapes into an opaque callee.
#   - NO aggregate crosses an extern-reaching frame (byval poison class):
#     MonotonicInstant is reduced to its UInt64 ticks BEFORE any probe
#     call, and the address travels as a rebound machine-word-backed
#     pointer.

from mojito_sys.abi.errors import raise_errno
from mojito_sys.sync.common import WaitStatus
import mojito_sys.sync.externs as _externs
from mojito_sys.time.monotonic import MonotonicInstant

from std.memory import stack_allocation

comptime ETIMEDOUT_DARWIN_RC = Int32(-60)
comptime ETIMEDOUT_LINUX_RC = Int32(-110)

# Host-spelled absent-backend status of the C layer (-ENOSYS), exposed for
# detection only; never swallowed here.
comptime ENOSYS_DARWIN_RC = Int32(-78)
comptime ENOSYS_LINUX_RC = Int32(-38)


def _null_deadline() -> _externs.DeadlineSlot:
    # b2 rejects `unsafe_from_address=0` as a literal; the zero travels
    # through a runtime local (same pattern as mutex.mojo's _null_handle).
    return _externs.DeadlineSlot(unsafe_from_address=Int(0))


def _word_ptr[origin: Origin](address: UnsafePointer[UInt32, origin]) -> _externs.WordPtr:
    # Rebind a caller-origin u32 pointer to the extern leaf's MutAnyOrigin
    # word pointer WITHOUT dereferencing: one address round-trip through
    # Int, exactly the mutex/thread handle pattern. A null address is
    # rejected by the C layer (-EFAULT), never constructed here.
    return _externs.WordPtr(unsafe_from_address=Int(address))


# Shared rc -> WaitStatus decode (frozen-ABI mapping, see header above).
def _decode(rc: Int32) raises -> WaitStatus:
    if rc == 0:
        return WaitStatus.ok
    if rc == ETIMEDOUT_DARWIN_RC or rc == ETIMEDOUT_LINUX_RC:
        return WaitStatus.timed_out
    raise_errno(rc)
    return WaitStatus.ok  # unreachable


# Block the calling OS thread while *address == expected, until
# wake_one_u32/wake_all_u32(address) somewhere, the absolute monotonic
# `deadline` passing, or the word changing under the kernel's atomic
# re-check.
#
# Returns WaitStatus.ok when woken OR when the word did not hold
# `expected` at sleep time (futex EAGAIN — documented in the header block:
# both outcomes mean "re-read the word"), and WaitStatus.timed_out when
# the deadline expired first. SPURIOUS .ok IS PERMITTED BY CONTRACT: loop
# on the predicate.
#
# Raises (decoded errno): -ENOSYS where no backend exists (Windows et
# al.; raised immediately, NEVER sleeps), -EFAULT for a null address,
# anything else unexpected from the C layer.
#
# Blocking: YES while the word matches and no wake arrives (SYS-5) — the
# defining §14 primitive; bounded by `deadline` when given. Allocation:
# none beyond one stack deadline cell (SYS-4). Task-aware: no — parks the
# whole OS thread.
def _deadline_slot(
    deadline: Optional[MonotonicInstant],
    dl_cell: UnsafePointer[UInt64, MutAnyOrigin],
) -> _externs.DeadlineSlot:
    # The Optional branch lives HERE, in a helper with no extern call:
    # b2 1.0.0b2 miscompiles (LLVM "call parameter type does not match")
    # when a branch merge feeds an @extern invocation inside the SAME
    # function. Keep extern-calling frames straight-line.
    var slot = _null_deadline()
    var dl = deadline
    if dl:
        dl_cell[] = dl.take().ticks
        slot = dl_cell
    return slot


# Block the calling OS thread while *address == expected, until a wake
# on address, the deadline, or the word changing. Returns WaitStatus.ok
# when woken OR the word did not hold `expected` at sleep time;
# WaitStatus.timed_out when the deadline expired first. SPURIOUS .ok IS
# PERMITTED: loop on the predicate (see wait_until_changed).
#
# Raises (decoded errno): -ENOSYS where no backend exists, -EFAULT for
# a null address, anything else unexpected from the C layer.
#
# Blocking: YES while the word matches and no wake arrives (SYS-5),
# bounded by `deadline` when given.
# Allocation: none beyond one stack deadline cell (SYS-4).
# Task-aware: no — parks the whole OS thread.
def wait_on_u32[origin: Origin](
    address: UnsafePointer[UInt32, origin],
    expected: UInt32,
    deadline: Optional[MonotonicInstant],
) raises -> WaitStatus:
    var dl_cell = stack_allocation[1, UInt64]()
    # FFI boundary: the extern leaf spells the compared value as Int32
    # (b2 lowers a UInt32 scalar across the extern boundary into a
    # byval pointer — the byval-poison class); Int32(UInt32) is a
    # BIT-PRESERVING reinterpretation, so the kernel sees exactly the
    # caller's word.
    var addr = _word_ptr(address)
    var exp = Int32(expected)
    var dl_slot = _deadline_slot(deadline, dl_cell)
    var rc = _externs.probe_wait_on(addr, exp, dl_slot)
    return _decode(rc)


# Wake ONE waiter blocked on address (exact count, 0 when none waited).
# Non-raising per the spec signature: negative returns are raw frozen-ABI
# -errno statuses (-ENOSYS without a backend, -EFAULT for null) — visible,
# never swallowed.
#
# Blocking: no (SYS-5) — wakes a waiter but never waits itself.
# Allocation: none (SYS-4).
# Task-aware: no.
def wake_one_u32[origin: Origin](address: UnsafePointer[UInt32, origin]) -> Int:
    return Int(_externs.probe_wake_one(_word_ptr(address)))


# Wake ALL waiters currently blocked on address (exact count). Same
# non-raising status convention as wake_one_u32.
#
# Blocking: no (SYS-5) — wakes waiters but never waits itself.
# Allocation: none (SYS-4).
# Task-aware: no.
def wake_all_u32[origin: Origin](address: UnsafePointer[UInt32, origin]) -> Int:
    return Int(_externs.probe_wake_all(_word_ptr(address)))


# Reference spurious-tolerance shape (contract documentation made code):
# wait until *address differs from `old`, looping over .ok results and
# re-checking the predicate after EVERY wake. False only on timeout.
#
# Blocking: yes while the word stays unchanged (SYS-5), bounded by
# deadline. Allocation: one stack deadline cell. Task-aware: no.
def wait_until_changed[origin: Origin](
    address: UnsafePointer[UInt32, origin],
    old: UInt32,
    deadline: MonotonicInstant,
) raises -> Bool:
    var addr = _word_ptr(address)
    var dl_cell = stack_allocation[1, UInt64]()
    while MonotonicInstant.now() < deadline:
        dl_cell[] = deadline.ticks
        var st_rc = _externs.probe_wait_on(addr, Int32(old), dl_cell)
        if _decode(st_rc) == WaitStatus.timed_out:
            return False
        if address[] != old:
            return True
        # Spurious or predicated .ok: loop and re-wait.
    return False
