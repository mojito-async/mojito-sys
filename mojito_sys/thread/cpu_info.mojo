# mojito-sys S2.6 — CPU topology queries (issue #53, spec §13).
#
# Module-level factories over the frozen s2-cpu C ABI
# (native/include/mojito_sys.h):
#   mjs_cpu_logical()        -> logical CPU count (> 0), or a negative errno;
#   mjs_cpu_physical(int *out) -> 0 with *out > 0 XOR exactly -ENOTSUP with
#                                 *out untouched; never any other errno.
#
# SPELLING NOTE (spec L900-910): the spec sketches CpuInfo.logical_count()
# / physical_count() as @staticmethod members. b2 DOES support static
# methods repo-wide (27 sites on main), but the issue-of-record spelling for
# this lane ships the MODULE-LEVEL forms cpu_logical_count() /
# cpu_physical_count() — matching mojito_sys.time.monotonic's module-level
# surface — and no CpuInfo struct at all: a typeless namespace would add an
# empty shell around two free functions (SYS-1 economy).
#
# Topology is ADVISORY (spec §13): counts are informational and may change
# under the caller (hotplug, cpuset restrictions); nothing here may be used
# to size a hard invariant.
#
# ENOTSUP MAPPING: darwin numbers ENOTSUP = 45; Linux spells it EOPNOTSUPP/
# ENOTSUP = 95. The frozen C contract permits EXACTLY this errno as the
# "undeterminable" answer (SYS-7 divergence made VISIBLE upstream as
# Optional[Int].None), so both platform spellings map to None and ANY other
# negative rc raises through the straight-line raise_errno path.
#
# b2 conventions (matching mojito_sys/time/monotonic.mojo, issue #63):
#   - @extern + abi("C") + `...`; dylib chosen at link time (-Xlinker).
#   - Out-slots are UnsafePointer[Int32, MutAnyOrigin]: the pointer escapes
#     into an opaque callee, and MutAnyOrigin pins the post-call slot load
#     AFTER the call.
#   - Raw mjs_* externs are importable but NOT for caller use.

from mojito_sys.abi.errors import raise_errno
from std.collections import Optional
from std.memory import UnsafePointer, stack_allocation

comptime IntOut = UnsafePointer[Int32, MutAnyOrigin]

# darwin errno numbering (mojito_sys/abi/errors.mojo table): ENOTSUP = 45.
comptime _ENOTSUP_DARWIN = Int32(-45)

# Linux errno numbering: ENOTSUP is the EOPNOTSUPP alias = 95.
comptime _ENOTSUP_LINUX = Int32(-95)


@extern("mjs_cpu_logical")
def mjs_cpu_logical() abi("C") -> Int32:
    ...

@extern("mjs_cpu_physical")
def mjs_cpu_physical(out_slot: IntOut) abi("C") -> Int32:
    ...


# Number of logical CPUs visible to this process (Linux sysconf
# _SC_NPROCESSORS_ONLN / darwin sysconf). Always >= 1 on a supported host.
# Blocking: no (single non-blocking libc query).
# Allocates: no.
# Thread-safe: yes (pure query).
# Reentrant: yes.
# Signal-safe: no guarantee (sysconf is not async-signal-safe). Task-aware: no.
# Ownership: value semantics; nothing retained.
# Platform notes: advisory count — hotplug/cpuset may change it any time.
# Stability: experimental.
def cpu_logical_count() raises -> Int:
    var n = mjs_cpu_logical()
    if n <= 0:
        # Frozen ABI failure convention: already a negative errno.
        raise_errno(n)
    return Int(n)


# Number of physical (package) cores, best-effort per spec §13: Some(count)
# when the host exposes it, None when undeterminable (the C layer reports
# EXACTLY -ENOTSUP; both the darwin 45 and Linux 95 spellings map here).
# Any other errno raises — a wrong-but-plausible errno must never silently
# masquerade as "unknown topology".
# Blocking: no (single sysctl/sysfs query).
# Allocates: one stack slot for the out-cell (no heap traffic).
# Thread-safe: yes (pure query).
# Reentrant: yes.
# Signal-safe: no guarantee (underlying libc queries are not
#   async-signal-safe). Task-aware: no.
def cpu_physical_count() raises -> Optional[Int]:
    var cell = stack_allocation[1, Int32]()
    var rc = mjs_cpu_physical(cell)
    var result = Optional[Int]()
    if rc == 0:
        result = Optional[Int](Int(cell[]))
    elif rc != _ENOTSUP_DARWIN and rc != _ENOTSUP_LINUX:
        # A wrong-but-plausible errno must never silently masquerade as
        # "unknown topology": anything but success/-ENOTSUP raises.
        raise_errno(rc)
    return result
