# mojito-sys S1 — VirtualMemory semantic conformance (issue #29)
#
# Exercises the mojito_sys.memory.virtual_memory wrapper end-to-end against
# the host OS through the frozen mjs_vm_* C ABI:
#   VM1  reserve: reservation size, alignment, nonzero base
#   VM2  commit: committed high-water updates
#   VM3  write/read verify across committed pages
#   VM4  protect READ: reads still work
#   VM5  protect WRITE: writes work again
#   VM6  decommit + re-commit round trip
#   VM7  release; double release is a no-op
#   VM8  host page-size constant sanity
#
# All pages are 16384 bytes on this host. Access to decommitted pages is a
# hard fault by design and is deliberately NOT probed here (the guard-fault
# proof lives in the C probe harness); this suite only exercises legal
# state transitions.
from mojito_sys.memory.virtual_memory import (
    VirtualMemory,
    Protection,
    PAGESIZE,
)

comptime BytePtr = UnsafePointer[UInt8, MutAnyOrigin]

def ptr(a: Int) -> BytePtr:
    return UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(a))

def check(name: String, cond: Bool) -> Bool:
    print(name + " " + ("PASS" if cond else "FAIL"))
    return cond


def main() raises:
    var failures = 0
    var ps = PAGESIZE
    ok = check("VM8 page-size 16384", ps == 16384)
    if not ok:
        failures += 1

    var vm = VirtualMemory.reserve(2 * ps)
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

    vm.protect(0, ps, Protection.write())
    p0[0] = UInt8(0x2B)
    ok = check("VM5 write-after-WRITE-protect", p0[0] == UInt8(0x2B))
    if not ok:
        failures += 1

    vm.decommit(ps, ps)
    ok = check("VM6a decommit ok", vm.reserved_bytes == 2 * ps)
    if not ok:
        failures += 1
    vm.commit(ps, ps)
    p0[ps + 7] = UInt8(0x77)
    ok = check("VM6b re-commit writable", p0[ps + 7] == UInt8(0x77))
    if not ok:
        failures += 1

    vm.release()
    ok = check("VM7a released reserved", vm.reserved_bytes == 0)
    if not ok:
        failures += 1
    vm.release()
    ok = check("VM7b double release no-op", vm.reserved_bytes == 0)
    if not ok:
        failures += 1

    print("RESULT: " + String(12 - failures) + "/12 PASSED")
    if failures != 0:
        raise Error("VirtualMemory conformance FAILED (issue #29)")
