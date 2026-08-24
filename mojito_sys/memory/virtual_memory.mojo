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
#   - COMPILER WORKAROUND (b2, verified by bisection): a raising member
#     of a (Movable) struct that lowers a String conversion raise — e.g.
#     `raise Error(String(rc))` — anywhere in the same function as another
#     raise site (literal or not) crashes the compiler (SIGSEGV in codegen).
#     Every ABI-calling raising member therefore has EXACTLY ONE raise site,
#     carrying the negative errno via `Error(String(rc))`; mistaken use of a
#     released reservation is not pre-checked in Mojo — the C side validates
#     NULL/live mappings and returns -EINVAL, which surfaces through that
#     same single raise.
#
# Page model: host page is 16384 bytes (mojolang toolchain, arm64). The
# underlying mprotect demands page-aligned, page-multiple ranges, so this
# wrapper rounds `offset` down and `offset+bytes` up to page boundaries
# before crossing the ABI; callers may pass arbitrary byte offsets.

from std.memory import stack_allocation

# POSIX protection bits (<sys/mman.h>): non-mutually-exclusive bit flags.
comptime PROT_NONE = 0x00
comptime PROT_READ = 0x01
comptime PROT_WRITE = 0x02
comptime PROT_EXEC = 0x04

# Host page size (bytes). The page-size lane owns mjs_page_size; mirror it as
# a comptime here so this wrapper stays standalone for testing.
comptime PAGESIZE = 16384

# C `void *` transported as a machine word (Int is 64-bit on LP64). Out-slots
# are cells holding raw addresses that C reads/writes through.
comptime OutSlots = UnsafePointer[Int, MutUntrackedOrigin]


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
# requires page-aligned, page-multiple ranges).
def _page_down(n: Int) -> Int:
    return n & ~(PAGESIZE - 1)


def _page_up(n: Int) -> Int:
    return (n + (PAGESIZE - 1)) & ~(PAGESIZE - 1)


# ---------------------------------------------------------------------------
# Protection: the fixed set of POSIX mprotect flag values a caller passes to
# VirtualMemory::protect. Called as Protection.read() / .write() / .none() /
# .execute(); bits are comptime-frozen so callers cannot invent flags.
struct Protection:
    var bits: Int32

    def __init__(out self, bits: Int32):
        self.bits = bits

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


# ---------------------------------------------------------------------------
# VirtualMemory: one host virtual-address reservation (spec §9).
#
# base            : first byte of the reserved range (raw address, page-aligned).
# reserved_bytes  : total bytes of address space reserved.
# committed_bytes : highest committed end offset (bytes past base); a
#                   high-water mark the wrapper keeps for callers, lowered by
#                   release. Not used to authorize access.
#
# Ownership: the value owns its reservation; __deinit__ releases it exactly
# once. Move semantics transfer the reservation (moved-from values hold
# none). Callers may release() explicitly at any time.
struct VirtualMemory(Movable):
    var base: Int
    var reserved_bytes: Int
    var committed_bytes: Int

    def __init__(out self):
        self.base = 0
        self.reserved_bytes = 0
        self.committed_bytes = 0

    def __moveinit__(mut self, mut existing: Self):
        self.base = existing.base
        self.reserved_bytes = existing.reserved_bytes
        self.committed_bytes = existing.committed_bytes
        existing.base = 0
        existing.reserved_bytes = 0
        existing.committed_bytes = 0

    def __deinit__(deinit self):
        if self.base != 0:
            var slot = stack_allocation[1, Int]()
            slot[] = self.base
            var rc = mjs_vm_release(slot, self.reserved_bytes)
            if rc != 0:
                # Best-effort only: region stays mapped; fields kept so a
                # later retry is possible.
                print("VirtualMemory warning: release rc=" + String(rc))
                return
            self.base = 0
            self.reserved_bytes = 0
            self.committed_bytes = 0

    @staticmethod
    def reserve(bytes: Int) raises -> Self:
        var base_out = stack_allocation[1, Int]()
        var size_out = stack_allocation[1, Int]()
        var rc = mjs_vm_reserve(bytes, base_out, size_out)
        if rc != 0:
            raise Error(String(rc))
        # Copy slot words into locals FIRST: `var vm` below is another stack
        # allocation and must not alias the out-slot scratch.
        var slab_base = base_out[]
        var slab_size = size_out[]
        var vm = VirtualMemory()
        vm.base = slab_base
        vm.reserved_bytes = slab_size
        return vm^

    def commit(mut self, offset: Int, length: Int) raises:
        var start: Int = _page_down(offset)
        var end: Int = _page_up(offset + length)
        var size: Int = end - start
        var addr = stack_allocation[1, Int]()
        addr[] = self.base + start
        var rc = mjs_vm_commit(addr, size)
        if rc != 0:
            raise Error(String(rc))
        if end > self.committed_bytes:
            self.committed_bytes = end

    def decommit(mut self, offset: Int, length: Int) raises:
        var start: Int = _page_down(offset)
        var end: Int = _page_up(offset + length)
        var addr = stack_allocation[1, Int]()
        addr[] = self.base + start
        var rc = mjs_vm_decommit(addr, end - start)
        if rc != 0:
            raise Error(String(rc))

    def protect(
        mut self,
        offset: Int,
        length: Int,
        protection: Protection,
    ) raises:
        var start: Int = _page_down(offset)
        var end: Int = _page_up(offset + length)
        var rc = mjs_vm_protect(self.base + start, end - start, protection.bits)
        if rc != 0:
            raise Error(String(rc))

    def release(mut self):
        if self.reserved_bytes == 0:
            return  # already released: no-op
        var base = stack_allocation[1, Int]()
        base[] = self.base
        # Spec §9.1 pins `release` as non-raising; a failed munmap of a live
        # reservation is unrecoverable, so the fields are zeroed regardless.
        var rc = mjs_vm_release(base, self.reserved_bytes)
        if rc != 0:
            print("VirtualMemory release failed")
        self.base = 0
        self.reserved_bytes = 0
        self.committed_bytes = 0
