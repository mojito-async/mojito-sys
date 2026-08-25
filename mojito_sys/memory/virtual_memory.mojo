# mojito-sys memory/virtual_memory — VirtualMemory + Protection (issue #29)
#
# Spec §9.1: explicit virtual-address reservation, commit, decommit,
# protection and release, backed by the frozen mjs_vm_* C ABI in
# native/include/mojito_sys.h (issue #24). This is the Mojo half of the
# S1 virtual-memory lane.
#
# Mojo 1.0.0b2 conventions (matching spike/mojito_spike.mojo, the S1 build
# scaffold, and mojito_sys/memory/stack.mojo — issue #30):
#   - @extern("<c_symbol>") + abi("C") + `...` body; dylib chosen at link
#     time (-Xlinker libmojito_sys.dylib).
#   - UnsafePointer origin must be concrete in extern signatures: raw
#     addresses handed to / received from C are MutAnyOrigin; scratch slots
#     carved with std.memory.stack_allocation are MutUntrackedOrigin.
#   - C `void *` is transported as a machine word: Int cells (64-bit LP64).
#     This lane stores the reservation base as `Int` and rebuilds a pointer
#     where one is required (deviation from §9.1's speculative UnsafePointer
#     field, per the spike's proven conventions).
#   - def only; owning value structs are declared (Movable) with
#     __moveinit__ / __deinit__ exactly like the stack lane (issue #30).
#   - COMPILER WORKAROUND (b2, verified by bisection, issue #29): a String
#     LITERAL reaching a `raise Error(...)` payload through ANY control-flow
#     merge (branch/loop, helper or inline, any module) crashes the compiler
#     when the raising member belongs to a (Movable) struct in a module that
#     also lowers @extern bindings. Every ABI-calling raising member there-
#     fore has EXACTLY ONE raise site and funnels BOTH bounds-validation
#     failures (H3) and negative-errno ABI returns through the straight-line
#     `raise_errno(rc)` helper in mojito_sys/abi/errors (H6), which decodes
#     errno names from Int-packed table data instead of leaking raw numbers.
#     Mistaken use of a released reservation is not pre-checked in Mojo —
#     the C side validates NULL/live mappings and returns -EINVAL, surfacing
#     through that same single raise.
#
# Page model: the rounding quantum is the HOST PAGE SIZE queried from the
# page-size SSOT (`page_size()` in mojito_sys.memory.page, issue #28) at
# reserve time — never a hardcoded constant (H4). Reservations themselves
# round up to the allocation GRANULARITY on the C side (H5); commit/
# decommit/protect round their ranges to the page quantum here before
# crossing the ABI, so callers may pass arbitrary byte offsets.

from mojito_sys.abi.errors import raise_errno
from mojito_sys.memory.page import page_size
from std.io import FileDescriptor
from std.memory import stack_allocation

# POSIX protection bits (<sys/mman.h>): non-mutually-exclusive bit flags.
comptime PROT_NONE = 0x00
comptime PROT_READ = 0x01
comptime PROT_WRITE = 0x02
comptime PROT_EXEC = 0x04

# darwin EINVAL (see mojito_sys/abi/errors.mojo errno table). Carried as an
# rc so range-validation failures share the ABI path's single raise site.
comptime _EINVAL_RC = Int32(-22)

# C `void *` transported as a machine word (Int is 64-bit on LP64). Out-slots
# are cells holding raw addresses that C reads/writes through. The origin MUST
# be MutAnyOrigin: these pointers escape into an opaque @extern callee, and an
# UntrackedOrigin-typed slot lets the optimizer hoist the post-call slot load
# ABOVE the call, reading stale garbage (StressLane -O hazard). MutAnyOrigin
# marks the pointer as ABI-escaping, pinning the load after the call.
comptime OutSlots = UnsafePointer[Int, MutAnyOrigin]


# ---------------------------------------------------------------------------
# Frozen C ABI (native/include/mojito_sys.h). Types match the header on this
# LP64 host: size_t and void* are 8 bytes (Mojo Int), int is Int32.
# ---------------------------------------------------------------------------

@extern("mjs_vm_reserve")
def mjs_vm_reserve(
    bytes: Int,
    out_base: OutSlots,
    out_reserved: OutSlots,
) abi("C") -> Int32:
    ...


@extern("mjs_vm_commit")
def mjs_vm_commit(addr: OutSlots, length: Int) abi("C") -> Int32:
    ...


@extern("mjs_vm_decommit")
def mjs_vm_decommit(addr: OutSlots, length: Int) abi("C") -> Int32:
    ...


@extern("mjs_vm_protect")
def mjs_vm_protect(addr: Int, length: Int, flags: Int32) abi("C") -> Int32:
    ...


@extern("mjs_vm_release")
def mjs_vm_release(base: OutSlots, reserved: Int) abi("C") -> Int32:
    ...


# ---------------------------------------------------------------------------
# page-rounding helpers (callers may pass arbitrary byte counts; mprotect
# requires page-aligned, page-multiple ranges). The rounding quantum comes
# from the page-size SSOT at reserve time — never a hardcoded constant (H4).
def _page_down(n: Int, quantum: Int) -> Int:
    return n & ~(quantum - 1)


def _page_up(n: Int, quantum: Int) -> Int:
    return (n + (quantum - 1)) & ~(quantum - 1)


# H3: a range must name real bytes INSIDE this reservation, validated BEFORE
# page-rounding so wild offsets/lengths cannot demote adjacent mappings.
def _validate_range(offset: Int, length: Int, reserved_bytes: Int) -> Int32:
    if offset < 0 or length < 0 or offset + length > reserved_bytes:
        return _EINVAL_RC
    return 0


# ---------------------------------------------------------------------------
# Protection: the fixed set of POSIX mprotect flag values a caller passes to
# VirtualMemory::protect. Called as Protection.none() / .read() / .write() /
# .execute() / .read_write() / .read_execute(); there is no public way to
# invent flag combinations (panel S2): the bits field is private and the
# constructor exists only for the factories above.
struct Protection:
    # Private by convention (underscore): read access goes through flags();
    # callers cannot mutate or hand-roll bit patterns.
    var _bits: Int32

    # Internal — construct via the named factories, never directly (S2).
    def __init__(out self, bits: Int32):
        self._bits = bits

    @staticmethod
    def none() -> Self:
        return Protection(Int32(PROT_NONE))

    @staticmethod
    def read() -> Self:
        return Protection(Int32(PROT_READ))

    @staticmethod
    def write() -> Self:
        return Protection(Int32(PROT_WRITE))

    @staticmethod
    def execute() -> Self:
        return Protection(Int32(PROT_EXEC))

    @staticmethod
    def read_write() -> Self:
        return Protection(Int32(PROT_READ | PROT_WRITE))

    @staticmethod
    def read_execute() -> Self:
        return Protection(Int32(PROT_READ | PROT_EXEC))

    # The frozen flag word passed to mprotect. Diagnostic/ABI boundary use.
    def flags(self) -> Int32:
        return self._bits


# ---------------------------------------------------------------------------
# VirtualMemory: one host virtual-address reservation (spec §9).
#
# base            : first byte of the reserved range (raw address, aligned).
# reserved_bytes  : total bytes of address space reserved (granularity-
#                   rounded by mjs_vm_reserve; bytes==0 reserves one granule).
# committed_bytes : highest committed end offset (bytes past base); a
#                   high-water mark the wrapper keeps for callers, lowered by
#                   release. Decommit does NOT lower it (it tracks commits
#                   only); protect() never touches it and succeeds silently
#                   on still-reserved (PROT_NONE) ranges.
# quantum         : host page size (page_size()) captured at reserve time;
#                   all wrapper-side range rounding uses this value (H4).
#
# Blocking behavior (SYS-5): reserve/commit/decommit/protect/release each
# perform synchronous syscalls (and commit faults pages in on first touch);
# none of them returns asynchronously.
#
# Ownership: the value owns its reservation; __deinit__ releases it exactly
# once. Move semantics transfer the reservation (moved-from values hold
# none). Callers may release() explicitly at any time.
struct VirtualMemory(Movable):
    var base: Int
    var reserved_bytes: Int
    var committed_bytes: Int
    var quantum: Int

    def __init__(out self):
        self.base = 0
        self.reserved_bytes = 0
        self.committed_bytes = 0
        self.quantum = 0

    def __moveinit__(mut self, mut existing: Self):
        self.base = existing.base
        self.reserved_bytes = existing.reserved_bytes
        self.committed_bytes = existing.committed_bytes
        self.quantum = existing.quantum
        existing.base = 0
        existing.reserved_bytes = 0
        existing.committed_bytes = 0
        existing.quantum = 0

    def __deinit__(deinit self):
        if self.base != 0:
            var slot = stack_allocation[1, Int]()
            slot[] = self.base
            var rc = mjs_vm_release(slot, self.reserved_bytes)
            if rc != 0:
                # Failure policy (S1): KEEP state so a retry stays possible;
                # exactly one stderr diagnostic carrying the raw rc.
                _diag(
                    "VirtualMemory warning: __deinit__ release failed rc="
                    + String(rc)
                    + "\n"
                )
                return
            self.base = 0
            self.reserved_bytes = 0
            self.committed_bytes = 0

    # Reserve address space. bytes==0 reserves one granularity unit (the
    # C side rounds every request up to mjs_granularity()). Blocking (SYS-5).
    @staticmethod
    def reserve(bytes: Int) raises -> Self:
        var base_out = stack_allocation[1, Int]()
        var size_out = stack_allocation[1, Int]()
        var rc = mjs_vm_reserve(bytes, base_out, size_out)
        if rc != 0:
            raise_errno(rc)
        # Copy slot words into locals FIRST: `var vm` below is another stack
        # allocation and must not alias the out-slot scratch.
        var slab_base = base_out[]
        var slab_size = size_out[]
        var vm = VirtualMemory()
        vm.base = slab_base
        vm.reserved_bytes = slab_size
        vm.quantum = page_size()
        return vm^

    # Make [offset, offset+length) readable/writable. Ranges are rounded to
    # the page quantum and must lie inside this reservation (H3). Blocking.
    def commit(mut self, offset: Int, length: Int) raises:
        var rc = _validate_range(offset, length, self.reserved_bytes)
        if rc == 0:
            var start = _page_down(offset, self.quantum)
            var end = _page_up(offset + length, self.quantum)
            var addr = stack_allocation[1, Int]()
            addr[] = self.base + start
            rc = mjs_vm_commit(addr, end - start)
            if rc == 0 and end > self.committed_bytes:
                self.committed_bytes = end
        if rc != 0:
            raise_errno(rc)

    # Return [offset, offset+length) to inaccessible zero-fill-on-recommit
    # state (kernel-guaranteed via the C side's re-seal). Does NOT lower
    # committed_bytes (high-water mark; only release resets it). Blocking.
    def decommit(mut self, offset: Int, length: Int) raises:
        var rc = _validate_range(offset, length, self.reserved_bytes)
        if rc == 0:
            var start = _page_down(offset, self.quantum)
            var end = _page_up(offset + length, self.quantum)
            var addr = stack_allocation[1, Int]()
            addr[] = self.base + start
            rc = mjs_vm_decommit(addr, end - start)
        if rc != 0:
            raise_errno(rc)

    # Apply protection bits to [offset, offset+length). Succeeds silently on
    # ranges that are merely reserved (still PROT_NONE) — protection of an
    # uncommitted range changes nothing observable until commit. Blocking.
    def protect(
        mut self,
        offset: Int,
        length: Int,
        protection: Protection,
    ) raises:
        var rc = _validate_range(offset, length, self.reserved_bytes)
        if rc == 0:
            var start = _page_down(offset, self.quantum)
            var end = _page_up(offset + length, self.quantum)
            rc = mjs_vm_protect(self.base + start, end - start, protection.flags())
        if rc != 0:
            raise_errno(rc)

    # Explicitly release the reservation. Returns 0 on success (or if
    # already released: idempotent no-op); on munmap failure returns the
    # negative-errno rc and KEEPS all fields (S1 unified policy) so a retry
    # remains possible — mirroring __deinit__. Non-raising per spec §9.1.
    def release(mut self) -> Int32:
        if self.reserved_bytes == 0:
            return 0  # already released: no-op
        var base = stack_allocation[1, Int]()
        base[] = self.base
        var rc = mjs_vm_release(base, self.reserved_bytes)
        if rc != 0:
            return rc
        self.base = 0
        self.reserved_bytes = 0
        self.committed_bytes = 0
        return 0


# S1: exactly one stderr diagnostic channel for release failures — never
# stdout, which pollutes embedders' program output.
def _diag(message: String):
    var err = FileDescriptor(2)
    err.write(message)
