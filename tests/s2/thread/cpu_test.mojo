# mojito-sys S2 — cpu topology + current-thread affinity Mojo conformance
# (issue #53, spec §13).
#
# Drives the mojito_sys.thread surface (cpu_info + affinity wrappers bound to
# the frozen s2-cpu C ABI, native/include/mojito_sys.h) through the §13
# acceptance list:
#
#   1. logical-positive      — cpu_logical_count() >= 1;
#   2. logical-host-agreement — equals the host truth captured by the
#     runner (sysctl hw.logicalcpu on darwin, getconf _NPROCESSORS_ONLN
#     on Linux) via MOJITO_HOST_LOGICAL — the same source of truth the
#     native smoke lane (tests/s2/native/cpu_smoke.c) asserts against;
#   3. physical-none-or-positive — cpu_physical_count() is Optional.None
#     (exactly -ENOTSUP upstream) or Some(positive); never a crash and
#     never any other observable errno;
#   4. physical-host-agreement — when the host exposes a physical core
#     count (MOJITO_HOST_PHYSICAL), Some() agrees with it;
#   5. affinity-full-set     — pinning to [0, logical_count) succeeds on
#     Linux; on darwin success OR exactly SysError ENOTSUP (SYS-7 visible
#     divergence; thread affinity is advisory there), NEVER any other
#     error and never a crash;
#   6. affinity-single-cpu   — CpuSet.from_mask(1) obeys the same
#     success-or-ENOTSUP contract through the builder path;
#   7. empty-set-einval      — an empty CpuSet raises EINVAL (frozen ABI:
#     nwords == 0 -> -EINVAL), detected before crossing the ABI;
#   8. builder-semantics     — from_range/from_mask bit placement,
#     word-boundary crossings, contains(), and the capacity guard.
#
# b2 conventions (matching tests/s1/*/ + tests/s4/time conventions):
#   - Exactly ONE raise site with a CONSTANT payload: String literals must
#     never reach a raise payload through a control-flow merge in a module
#     that lowers @extern bindings (issue #29 H6). Diagnostics go to
#     stdout; failures accumulate in `failed`.
#   - Errno detection on raised errors matches on the decoded NAME
#     ("ENOTSUP" / "EINVAL") via SysError.to_string's Int-packed table,
#     not on numbers.
#
# Run via tests/s2/thread/run.sh (builds libmojito_sys.dylib first).

from os import getenv

from mojito_sys.thread.affinity import CPUSET_MAX_CPUS, CpuSet, set_current_thread_affinity
from mojito_sys.thread.cpu_info import cpu_logical_count, cpu_physical_count


def check(name: String, cond: Bool) -> Bool:
    if cond:
        print("PASS", name)
        return True
    print("FAIL", name)
    return False


def errno_is(e: Error, name: String) -> Bool:
    # True iff the raised error's decoded message names `errno`
    # (raise_errno payloads carry the Int-packed table name).
    return String(e).find(name) != -1


def env_int(name: String) -> Int:
    # Runner-captured host fact; empty string means "host did not expose it".
    var v = getenv(name)
    if v.byte_length() == 0:
        return -1
    return Int(v)


def main() raises:
    var failed = 0

    # --- topology -------------------------------------------------------
    var logical = cpu_logical_count()
    if not check("logical-positive", logical >= 1):
        failed += 1

    var host_logical = env_int("MOJITO_HOST_LOGICAL")
    if host_logical > 0:
        if not check(
            "logical-host-agreement",
            logical == host_logical,
        ):
            failed += 1

    var physical_none_or_positive = True
    var physical_value = -1
    try:
        var physical = cpu_physical_count()
        if physical:
            physical_value = physical.take()
            physical_none_or_positive = physical_value > 0
    except e:
        # Any errno other than the documented -ENOTSUP path is a failure;
        # ENOTSUP itself must surface as Optional.None above, so reaching
        # this handler means the wrapper leaked a non-ENOTSUP errno.
        physical_none_or_positive = False
        print("   | unexpected raise:", String(e))
    if not check("physical-none-or-positive", physical_none_or_positive):
        failed += 1

    var host_physical = env_int("MOJITO_HOST_PHYSICAL")
    if host_physical > 0 and physical_value > 0:
        if not check(
            "physical-host-agreement",
            physical_value == host_physical,
        ):
            failed += 1

    # --- affinity ---------------------------------------------------------
    # darwin: thread_policy_set affinity is best-effort/advisory (SYS-7);
    # accept success or exactly ENOTSUP. Linux: sched_setaffinity must
    # succeed for a subset of the process's own mask.
    ok = True
    darwin = getenv("MOJITO_HOST_OS") == "darwin"
    try:
        set_current_thread_affinity(CpuSet.from_range(0, logical))
    except e:
        ok = darwin and errno_is(e, "ENOTSUP")
    if not check("affinity-full-set", ok):
        failed += 1

    ok = True
    try:
        set_current_thread_affinity(CpuSet.from_mask(UInt64(1)))
    except e:
        ok = darwin and errno_is(e, "ENOTSUP")
    if not check("affinity-single-cpu", ok):
        failed += 1

    # Empty set: frozen ABI maps nwords == 0 to -EINVAL; the wrapper
    # enforces it before crossing the ABI.
    ok = False
    try:
        set_current_thread_affinity(CpuSet.from_range(5, 5))
    except e:
        ok = errno_is(e, "EINVAL")
    if not check("empty-set-einval", ok):
        failed += 1

    # --- builder semantics -------------------------------------------------
    var cs = CpuSet.from_range(2, 5)
    ok = (
        cs.contains(2)
        and cs.contains(3)
        and cs.contains(4)
        and not cs.contains(1)
        and not cs.contains(5)
        and not cs.is_empty()
    )
    if not check("builder-from-range-bits", ok):
        failed += 1

    cs = CpuSet.from_mask(UInt64(0b1010))
    ok = cs.contains(1) and cs.contains(3) and not cs.contains(0)
    if not check("builder-from-mask-bits", ok):
        failed += 1

    # Word-boundary crossing: CPUs 60..69 span words 0 and 1.
    cs = CpuSet.from_range(60, 70)
    ok = cs.contains(60) and cs.contains(63) and cs.contains(64) and cs.contains(69)
    if not check("builder-word-boundary", ok):
        failed += 1

    # Capacity guard: beyond CPUSET_MAX_CPUS*64 bits must be rejected.
    ok = False
    try:
        _ = CpuSet.from_range(0, CPUSET_MAX_CPUS * 64 + 1)
    except e:
        ok = errno_is(e, "EINVAL")
    if not check("builder-capacity-guard", ok):
        failed += 1

    print("RESULT: " + String(8 - failed) + "/8 PASSED")
    if failed != 0:
        raise Error("s2-cpu-mojo conformance FAILED (issue #53)")
    print("RESULT: all green")
