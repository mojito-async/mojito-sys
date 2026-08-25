# mojito-sys S1 — non-moving guarded native stack wrapper (issue #30).
#
# Exposes the frozen native stack services of native/include/mojito_sys.h
# (mjs_stack_alloc / mjs_stack_free) as an owning Mojo struct: `NativeStack`
# mirrors spec 10. The C ABI is the binary-compatibility firewall; this
# module adds source-level naming, ownership and grow() service glue.
#
# Geometry (matches the C allocator and the S1 tests-memory contract):
#   base       = reservation base; guard region = [base, base+guard) PROT_NONE
#   guard_low  = first usable byte (base + guard)
#   top        = highest usable address, 16-byte aligned (initial SP)
#
# Ownership: NativeStack owns its reservation; __deinit__ releases it exactly
# once via mjs_stack_free. Move semantics transfer the reservation.
#
# Mojo 1.0.0b2 conventions (matching spike/mojito_spike.mojo and
# mojito_sys/memory/page.mojo):
#   - @extern("<c_symbol>") + abi("C") + `...` body; dylib chosen at link
#     time (-Xlinker libmojito_sys.dylib).
#   - UnsafePointer origins must be concrete in extern signatures: every
#     slot handed to / received from C is MutAnyOrigin (see ORIGIN HAZARD
#     at OutSlots below); stack_allocation scratch is fine as long as it
#     crosses an extern boundary only through that alias.
#   - def only (fn removed on b2); destructors are def __deinit__(deinit self).

from std.memory import stack_allocation

# C `void *` transported as a machine word (Int is 64-bit on LP64). Out-slots
# are cells holding raw addresses that C reads/writes through.
#
# ORIGIN HAZARD (StressLane, PR #39): UnsafePointer[Int, MutUntrackedOrigin]
# out-slots on OPAQUE extern calls get their post-call loads hoisted ABOVE
# the call under optimization, so Mojo re-reads stale pre-call slot words
# instead of what C wrote. Every slot handed to an extern here is therefore
# MutAnyOrigin: loads through that origin may not be reordered across the
# opaque call, so each op observes its own post-call slot values.
comptime OutSlots = UnsafePointer[Int, MutAnyOrigin]

@extern("mjs_stack_alloc")
def mjs_stack_alloc(
    reserve_bytes: Int,
    initial_commit_bytes: Int,
    guard_bytes: Int,
    out_base: OutSlots,
    out_guard_low: OutSlots,
    out_top: OutSlots,
) abi("C") -> Int32:
    ...


@extern("mjs_stack_free")
def mjs_stack_free(base: OutSlots) abi("C") -> Int32:
    ...


# VM-lane commit service (frozen in native/include/mojito_sys.h): makes
# [*addr, *addr+length) accessible in place on ANY previously mapped region
# and advances *addr past the committed run. Used by NativeStack.grow() to
# pin reserved-but-PROT_NONE pages to RW without moving anything.
@extern("mjs_vm_commit")
def mjs_vm_commit(addr: OutSlots, length: Int) abi("C") -> Int32:
    ...


struct NativeStack(Movable):
    """A non-moving, guarded native stack reservation (spec 10).

    Owns a fixed virtual-address region that never moves for its lifetime.
    The native stack grows DOWN from `top`; the first `guard_bytes` of the
    reservation (at `base`) are PROT_NONE, so overflow off the bottom of the
    usable range faults deterministically instead of corrupting memory.

    The value is movable; the destructor releases the reservation exactly
    once via mjs_stack_free.
    """

    var base: Int
    var guard_low: Int
    var top: Int
    var guard_bytes: Int
    var reserved_bytes: Int
    var committed_bytes: Int

    def __init__(out self):
        self.base = 0
        self.guard_low = 0
        self.top = 0
        self.guard_bytes = 0
        self.reserved_bytes = 0
        self.committed_bytes = 0

    @staticmethod
    def create(
        reserve_bytes: Int,
        initial_commit_bytes: Int,
        guard_bytes: Int,
    ) raises -> Self:
        # slots[0]=base  slots[1]=guard_low  slots[2]=top, written by C.
        var slots = stack_allocation[3, Int]()
        var rc = mjs_stack_alloc(
            reserve_bytes,
            initial_commit_bytes,
            guard_bytes,
            slots,
            slots + 1,
            slots + 2,
        )
        # Copy slot words into locals FIRST: `var ns` below is another stack
        # allocation and must not alias the out-slot scratch.
        var slab_base = slots[]
        var slab_guard_low = (slots + 1)[]
        var slab_top = (slots + 2)[]
        var ns = NativeStack()
        ns.base = slab_base
        ns.guard_low = slab_guard_low
        ns.top = slab_top
        ns.guard_bytes = guard_bytes
        ns.reserved_bytes = reserve_bytes
        ns.committed_bytes = initial_commit_bytes
        return ns^
    def __moveinit__(mut self, mut existing: Self):
        """Transfer the reservation: steal every field and null the source so
        the moved-from value's destructor releases nothing."""
        self.base = existing.base
        self.guard_low = existing.guard_low
        self.top = existing.top
        self.guard_bytes = existing.guard_bytes
        self.reserved_bytes = existing.reserved_bytes
        self.committed_bytes = existing.committed_bytes
        existing.base = 0
        existing.guard_low = 0
        existing.top = 0
        existing.guard_bytes = 0
        existing.reserved_bytes = 0
        existing.committed_bytes = 0

    def __deinit__(deinit self):
        if self.base != 0:
            var slot = stack_allocation[1, Int]()
            slot[] = self.base
            var rc = mjs_stack_free(slot)
            if rc != 0:
                # Best-effort only: region stays mapped; fields kept so a
                # later retry is possible.
                print(
                    "NativeStack warning: mjs_stack_free rc=" + String(rc),
                )
                return
            self.base = 0
            self.guard_low = 0
            self.top = 0
            self.committed_bytes = 0

    def is_live(self) -> Bool:
        return self.base != 0

    def base_address(self) -> Int:
        return self.base

    def guard_low_address(self) -> Int:
        return self.guard_low

    def top_address(self) -> Int:
        return self.top

    def total_reserved(self) -> Int:
        return self.reserved_bytes

    def committed(self) -> Int:
        return self.committed_bytes

    # ---- geometry / stability ---------------------------------------------

    def check_geometry(self) -> Bool:
        """base < guard_low <= top and top is 16-byte aligned."""
        if self.base < self.guard_low and self.guard_low <= self.top:
            return self.top % 16 == 0
        return False

    def write_at(self, addr: Int, value: UInt8) -> Bool:
        """Write one byte in [guard_low, top). False if outside the usable
        range (the guard region is never written from Mojo; the guard fault
        proof runs in a forked child process via the C probe)."""
        if addr < self.guard_low or addr >= self.top:
            return False
        var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=addr)
        p[] = value
        return True

    def read_byte(self, addr: Int) -> UInt8:
        var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=addr)
        return p[]

    def grow(mut self, additional_bytes: Int) raises:
        """Commit additional_bytes (a page multiple) in place via the frozen
        VM commit service, extending the committed span downward. `top` and
        every live address stay byte-identical.

        S1 keeps the C ABI frozen: growth is not a new C symbol — grow()
        reuses mjs_vm_commit (vm lane, issue #29), which flips a
        page-aligned, already-mapped PROT_NONE span to RW anywhere.
        """
        if additional_bytes == 0:
            return
        var remaining = (self.top - self.guard_low) - self.committed_bytes
        NativeStack._check_grow(
            additional_bytes < 0, additional_bytes > remaining,
            additional_bytes, remaining,
        )
        var span_start = self.top - self.committed_bytes - additional_bytes
        var rc = NativeStack._commit_raw(span_start, additional_bytes)
        NativeStack._commit_raise(rc)
        self.committed_bytes += additional_bytes



    @staticmethod
    def _check_grow(
        negative: Bool,
        beyond: Bool,
        additional: Int,
        remaining: Int,
    ) raises:
        """Raise-only bounds gate; kept extern-free (see _commit_raise note)."""
        if negative:
            raise Error("NativeStack.grow: negative additional_bytes")
        if beyond:
            raise Error(
                "NativeStack.grow: beyond reserved span (need "
                + String(additional) + ", have "
                + String(remaining) + " bytes left)",
            )

    @staticmethod
    def _commit_raw(span_start: Int, length: Int) -> Int32:
        """Extern-only commit helper; the raise lives in _commit_raise
        because the b2 compiler crashes when a single non-static function
        body both calls an extern and raises."""
        var slot = stack_allocation[1, Int]()
        slot[] = span_start
        return mjs_vm_commit(slot, length)

    @staticmethod
    def _commit_raise(rc: Int32) raises:
        if rc != 0:
            raise Error(
                "NativeStack.grow: mjs_vm_commit rc=" + String(rc)
                + " (vm-lane service not merged yet, issue #29)",
            )