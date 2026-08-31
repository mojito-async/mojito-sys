/*
 * mapping_probe.c -- M1.4 (#128) TEST-ONLY oracle: count this process's own
 * live virtual-memory regions. Same convention as tests/spike/t13_guard_probe.c
 * and spike/abi/oracle.c: a small C helper that exists purely to give a Mojo
 * test an independent, dynamically-measured signal, not a production shim
 * (spec §14's C-shim policy governs PRODUCTION code, not test oracles).
 *
 * "leak no mappings, checked against the process mapping count rather than
 * by inspection" (#128 acceptance) needs a way to count this process's own
 * mach vm regions; mach_vm_region_recurse_64 (what `vmmap` itself uses) is
 * the standard way to enumerate them on macOS. Used differentially: the
 * Mojo test calls msw_count_mappings() before and after an alloc/free
 * storm and asserts the count returns to (approximately) where it started,
 * so it is robust to whatever unrelated churn the host/runtime is doing,
 * rather than asserting an absolute number.
 */
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>

int msw_count_mappings(void) {
    task_t task = mach_task_self();
    mach_vm_address_t address = 0;
    int count = 0;

    for (;;) {
        mach_vm_size_t size = 0;
        natural_t depth = 1; /* flatten submaps into their leaf regions */
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;

        kern_return_t kr = mach_vm_region_recurse(
            task, &address, &size, &depth,
            (vm_region_recurse_info_t)&info, &info_count);
        if (kr != KERN_SUCCESS)
            break;

        if (info.is_submap) {
            depth++;
        } else {
            count++;
            address += size;
        }
    }
    return count;
}
