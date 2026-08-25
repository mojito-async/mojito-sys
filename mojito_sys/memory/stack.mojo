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
# Accounting SSOT (panel H4): reserved_bytes / committed_bytes derive from
# the C-RETURNED geometry (out-slots) and C's documented page rounding +
# clamp rules — never from the raw arguments. Recording raw requests let
# wrapper bookkeeping drift from the dylib's actual mapping and made grow()
# fail spuriously on non-page-multiple commits.
#
# Ownership: NativeStack owns its reservation; __deinit__ releases it exactly
# once via mjs_stack_free. Move semantics transfer the reservation.
#
# Mojo 1.0.0b2 conventions (matching spike/mojito_spike.mojo,
# mojito_sys/memory/page.mojo and mojito_sys/memory/virtual_memory.mojo):
#   - @extern("<c_symbol>") + abi("C") + `...` body; dylib chosen at link
#     time (-Xlinker libmojito_sys.dylib).
#   - UnsafePointer origins must be concrete in extern signatures: every
#     slot handed to / received from C is MutAnyOrigin (see ORIGIN HAZARD
#     at OutSlots below); stack_allocation scratch is fine as long as it
#     crosses an extern boundary only through that alias.
#   - def only (fn removed on b2); destructors are def __deinit__(deinit self).
#   - COMPILER WORKAROUND (b2, verified by bisection, issue #30 fold): a
#     raising member whose body also lowers an @extern call must keep
#     EXACTLY ONE raise site, funneled through `raise_errno(rc)`
#     (mojito_sys/abi/errors, H6) — mirroring virtual_memory.mojo — and
#     must NOT lower integer division/remainder in that same body (the
#     sdiv/srem pipeline SIGSEGVs the compiler there; host page sizes are
#     powers of two, so page rounding uses bit masks instead).

from std.memory import stack_allocation

from mojito_sys.abi.errors import raise_errno
from mojito_sys.memory.page import page_size

# darwin errno values carried as frozen negative-errno rc's (see the
# mojito_sys/abi/errors.mojo table); precondition failures share the ABI
# path's single decoded raise site instead of raising String literals
# through control-flow merges (b2 crash, issue #29/#30).
comptime _EINVAL_RC = Int32(-22)
comptime _ENOMEM_RC = Int32(-12)



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

    Blocking behavior (SYS-5): create/grow/__deinit__ each perform
    synchronous syscalls (mmap/mprotect/munmap; newly committed pages fault
    in on first touch) and raise on failure via the decoded errno path;
    no method returns asynchronously. All remaining public defs are pure
    wrapper reads or direct memory access with no syscall.

    base            : first byte of the reservation (raw address, aligned).
    guard_low       : first usable byte (base + guard_pages * page_size).
    top             : highest usable address, 16-byte aligned (initial SP).
    guard_bytes     : PROT_NONE guard size in bytes (positive page multiple;
                      validated by the C side, which raises -EINVAL otherwise).
    reserved_bytes  : total reservation size, from the C-returned geometry
                      (H4 SSOT).
    committed_bytes : bytes of the usable span currently RW, page-rounded
                      and clamped by the C allocator (H4 SSOT); advanced by
                      grow().
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
        """Reserve and initially-commit a guarded stack. Raises (decoded
        errno) on any C-level failure — guard validation, wrap-around,
        mmap/mprotect errors. Blocking (SYS-5)."""
        # Three one-word scratch cells written by C (vm-lane reserve
        # shape); derived multi-cell offsets miscompile here (issue #30).
        var out_base = stack_allocation[1, Int]()
        var out_guard_low = stack_allocation[1, Int]()
        var out_top = stack_allocation[1, Int]()
        var rc = mjs_stack_alloc(
            reserve_bytes,
            initial_commit_bytes,
            guard_bytes,
            out_base,
            out_guard_low,
            out_top,
        )
        # H1: on failure the frozen contract leaves out-slots UNTOUCHED, so
        # raise the decoded errno BEFORE any field copy or wrapper
        # construction — a caller can never observe a half-initialized or
        # poisoned handle (errors.mojo post-#41 path, single raise site).
        if rc != 0:
            raise_errno(rc)
        var ns = NativeStack()
        ns.base = out_base[]
        ns.guard_low = out_guard_low[]
        ns.top = out_top[]
        ns.guard_bytes = guard_bytes
        # H4: single source of truth — bookkeeping derives from the
        # C-returned geometry plus C's documented rounding/clamp rules,
        # never from the raw arguments. Page round-up is inlined as a
        # power-of-two bit mask (module-head workaround note: no called
        # rounding helper inside this raising ABI-calling member).
        var ps = page_size()
        ns.reserved_bytes = ns.top - ns.base
        var committed_req = (initial_commit_bytes + ps - 1) & ~(ps - 1)
        ns.committed_bytes = min(
            committed_req, ns.top - ns.guard_low,
        )
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

    # Releases the reservation wholesale (munmap). Blocking (SYS-5). The
    # pre-check keeps wrapper-level idempotency: moved-from values hold no
    # reservation, and the C side treats double-free as -EINVAL (H2).
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
        proof runs in a forked child process via the C probe). First touch
        of a committed page faults it in synchronously."""
        if addr < self.guard_low or addr >= self.top:
            return False
        var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=addr)
        p[] = value
        return True

    def read_byte(self, addr: Int) -> UInt8:
        """Read one byte from the usable span. Non-syscall; may fault a
        committed page in on first touch."""
        var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=addr)
        return p[]

    def grow(mut self, additional_bytes: Int) raises:
        """Commit additional_bytes (a page multiple) in place via the frozen
        VM commit service, extending the committed span downward. `top` and
        every live address stay byte-identical.

        S1 keeps the C ABI frozen: growth is not a new C symbol — grow()
        reuses mjs_vm_commit (vm lane, issue #29), which flips a
        page-aligned, already-mapped PROT_NONE span to RW anywhere.
        Raises (decoded errno) on a non-page-multiple request (SHOULD 1:
        explicit early gate, not a downstream mprotect EINVAL), a negative
        request, a request beyond the reserved span, or an mprotect failure.
        Blocking (SYS-5).
        """
        if additional_bytes == 0:
            return
        # COMPILER WORKAROUND (b2, mirrors virtual_memory.mojo): this
        # ABI-calling raising member has EXACTLY ONE raise site at the tail;
        # precondition violations set an errno rc instead of raising inline,
        # so no String literal ever reaches a payload through a merge.
        var ps = page_size()
        var rc = Int32(0)
        if additional_bytes < 0:
            rc = _EINVAL_RC
        if rc == 0 and (additional_bytes & (ps - 1)) != 0:
            rc = _EINVAL_RC
        if rc == 0:
            var remaining = (self.top - self.guard_low) - self.committed_bytes
            if additional_bytes > remaining:
                rc = _ENOMEM_RC
        if rc == 0:
            var span_start = (
                self.top - self.committed_bytes - additional_bytes
            )
            rc = NativeStack._commit_raw(span_start, additional_bytes)
        if rc != 0:
            raise_errno(rc)
        self.committed_bytes += additional_bytes

    @staticmethod
    def _commit_raw(span_start: Int, length: Int) -> Int32:
        """Extern-only commit helper; grow()'s single raise site consumes
        its rc (b2: an ABI-calling raising member keeps exactly one raise)."""
        var slot = stack_allocation[1, Int]()
        slot[] = span_start
        return mjs_vm_commit(slot, length)
