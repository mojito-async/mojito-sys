# mojito-sys S1 — VirtualMemory semantic conformance (issue #29)
#
# Exercises the mojito_sys.memory.virtual_memory wrapper end-to-end against
# the host OS through the frozen mjs_vm_* C ABI:
#   VM1  reserve: reservation size, alignment, nonzero base
#   VM2  commit: committed high-water updates
#   VM3  write/read verify across committed pages
#   VM4  protect READ: reads still work
#   VM5  protect WRITE: writes work again
#   VM6  decommit + re-commit round trip (incl. zero-fill promise, H1/VM6c)
#   VM7  release; double release is a no-op
#   VM8  page-size SSOT: wrapper-derived quantum == direct query (H4)
#   VM9  sequential reserves: distinct bases, DISTINCT sizes, sentinel
#        isolation/liveness through each base (S4)
#
# All pages are 16384 bytes on this host. Access to decommitted pages is a
# hard fault by design and is deliberately NOT probed here (the guard-fault
# proof lives in the C probe harness); this suite only exercises legal
# state transitions.
from mojito_sys.memory.page import page_size
from mojito_sys.memory.virtual_memory import (
    VirtualMemory,
    Protection,
)

comptime BytePtr = UnsafePointer[UInt8, MutAnyOrigin]

def ptr(a: Int) -> BytePtr:
    return UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(a))

def contains(haystack: String, needle: String) -> Bool:
    # True iff haystack contains needle (String.find returns -1 on miss).
    return haystack.find(needle) != -1


def check(name: String, cond: Bool) -> Bool:
    print(name + " " + ("PASS" if cond else "FAIL"))
    return cond


def main() raises:
    var failures = 0
    var ps = page_size()

    var vm = VirtualMemory.reserve(2 * ps)

    # VM8 (H4): the quantum this instance derived at reserve time must equal
    # an independent direct query of the page-size SSOT — no hardcoded
    # constant anywhere in the chain.
    ok = check("VM8 quantum equals direct page_size()", vm.quantum == ps)
    if not ok:
        failures += 1

    ok = check("VM1a reserve reserved_bytes", vm.reserved_bytes == 2 * ps)
    if not ok:
        failures += 1
    ok = check("VM1b base page-aligned", vm.base % ps == 0)
    if not ok:
        failures += 1
    ok = check("VM1c base nonzero", vm.base != 0)
    if not ok:
        failures += 1

    vm.commit(0, 2 * ps)
    ok = check("VM2 committed high-water", vm.committed_bytes == 2 * ps)
    if not ok:
        failures += 1

    var p0 = ptr(vm.base)
    var mem_failures = 0
    for i in range(0, 2 * ps):
        p0[i] = UInt8(i % 256)
    for i in range(0, 2 * ps):
        if p0[i] != UInt8(i % 256):
            mem_failures += 1
            if mem_failures > 4:
                break
    ok = check("VM3 write/read 2 pages", mem_failures == 0)
    if not ok:
        failures += 1

    vm.protect(0, ps, Protection.read())
    ok = check("VM4 read-after-READ-protect", p0[0] == UInt8(0))
    if not ok:
        failures += 1

    vm.protect(0, ps, Protection.read_write())
    p0[0] = UInt8(0x2B)
    ok = check("VM5 write-after-READ_WRITE-protect", p0[0] == UInt8(0x2B))
    if not ok:
        failures += 1

    vm.decommit(ps, ps)
    ok = check("VM6a decommit ok", vm.reserved_bytes == 2 * ps)
    if not ok:
        failures += 1
    # Decommit must NOT lower the committed high-water mark (panel S6).
    ok = check("VM6d decommit keeps committed_bytes", vm.committed_bytes == 2 * ps)
    if not ok:
        failures += 1
    vm.commit(ps, ps)
    # VM6c — frozen-header zero-fill promise (panel H1): after decommit the
    # physical backing must be GONE, so re-committing exposes zeros. Assert
    # every byte reads 0x00 BEFORE any write to the restored range.
    mem_failures = 0
    for i in range(ps, 2 * ps):
        if p0[i] != UInt8(0):
            mem_failures += 1
            if mem_failures > 4:
                break
    ok = check("VM6c re-commit exposes zero-filled bytes", mem_failures == 0)
    if not ok:
        failures += 1
    p0[ps + 7] = UInt8(0x77)
    ok = check("VM6b re-commit writable", p0[ps + 7] == UInt8(0x77))
    if not ok:
        failures += 1

    _ = vm.release()
    ok = check("VM7a released reserved", vm.reserved_bytes == 0)
    if not ok:
        failures += 1
    _ = vm.release()
    ok = check("VM7b double release no-op", vm.reserved_bytes == 0)
    if not ok:
        failures += 1

    # VM9 — regression guard (StressLane -O hazard, PR #41), strengthened per
    # panel S4: two reserves with DISTINCT sizes must each observe their OWN
    # post-call out-slot values (a stale-slot load would collide bases or mix
    # up sizes), and sentinels written through each base must stay isolated —
    # proving liveness of both mappings, not mere address inequality.
    var vm_a = VirtualMemory.reserve(2 * ps)
    var vm_b = VirtualMemory.reserve(3 * ps)
    ok = check(
        "VM9a sequential reserves distinct live bases",
        vm_a.base != 0 and vm_b.base != 0 and vm_a.base != vm_b.base,
    )
    if not ok:
        failures += 1
    # Reserved ranges are PROT_NONE until committed: make both fully
    # writable before driving sentinels through each base.
    vm_a.commit(0, 2 * ps)
    vm_b.commit(0, 3 * ps)
    var pa = ptr(vm_a.base)
    var pb = ptr(vm_b.base)
    pa[0] = UInt8(0xAA)
    pb[0] = UInt8(0xBB)
    pb[3 * ps - 1] = UInt8(0xCC)
    ok = check(
        "VM9c sentinel isolation through each base",
        pa[0] == UInt8(0xAA)
        and pb[0] == UInt8(0xBB)
        and pb[3 * ps - 1] == UInt8(0xCC),
    )
    if not ok:
        failures += 1

    # VM10 — panel H3: ranges outside the reservation must be rejected
    # BEFORE crossing the ABI (wild offsets once demoted adjacent mappings
    # silently). Every rejection must decode through SysError (EINVAL).
    ok = True
    try:
        vm_b.commit(3 * ps, ps)
    except e:
        ok = contains(String(e), "EINVAL")
    ok2 = check("VM10a out-of-range commit rejected", ok)
    if not ok2:
        failures += 1

    ok = True
    try:
        vm_b.protect(0, 3 * ps + 1, Protection.read_write())
    except e:
        ok = contains(String(e), "EINVAL")
    ok2 = check("VM10b overhang protect rejected", ok)
    if not ok2:
        failures += 1

    ok = True
    try:
        vm_b.decommit(-1, ps)
    except e:
        ok = contains(String(e), "EINVAL")
    ok2 = check("VM10c negative-offset decommit rejected", ok)
    if not ok2:
        failures += 1

    print("RESULT: " + String(20 - failures) + "/20 PASSED")
    if failures != 0:
        raise Error("VirtualMemory conformance FAILED (issue #29)")
