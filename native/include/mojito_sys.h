#ifndef MOJIT0_SYS_H
#define MOJIT0_SYS_H

#include <stddef.h>

/*
 * mojito-sys S1 — frozen C ABI (issue #24): page / VM / stack services.
 *
 * S1 contract:
 *   - Live stack addresses never move. Once a stack region is allocated and
 *     committed, its usable range is stable for the lifetime of the binding;
 *     mjs_stack_free returns it wholesale. (No stack growth/shrink in S1.)
 *   - Every stack region carries exactly one guard page at the LOW end of the
 *     reservation (below *out_guard_low), mapped PROT_NONE. Crossing it is a
 *     hard fault by design.
 *   - Compatibility: the signatures and semantics below are frozen for the
 *     S1 milestone. Extending the ABI means adding new names, never changing
 *     these declarations.
 *   - mjs_page_size / mjs_granularity are informational. Byte counts passed
 *     to commit/decommit/protect must be page-aligned and page multiples by
 *     the caller, as required by the underlying platform calls.
 */

/* Host page size (sysconf(_SC_PAGESIZE)); > 0. */
int mjs_page_size(void);

/* Allocation granularity for reservations; >= page size. */
int mjs_granularity(void);

/* Reserve `bytes` (rounded up to granularity) of address space without
 * committing physical memory (mmap NORESERVE-equivalent). On success returns
 * 0, stores the reservation base in *out_base and the exact reserved size in
 * *out_reserved. */
int mjs_vm_reserve(size_t bytes, void **out_base, size_t *out_reserved);

/* Commit (mlock-equivalent) `length` bytes at *addr. *addr is updated to the
 * first byte past the committed range. Returns 0 on success. */
int mjs_vm_commit(unsigned char **addr, size_t length);

/* Decommit `length` bytes at *addr; the range becomes inaccessible/zero fill
 * until re-committed. Returns 0 on success. */
int mjs_vm_decommit(unsigned char **addr, size_t length);

/* Change protection of `length` bytes at *addr to mprotect_flags
 * (PROT_READ/PROT_WRITE/PROT_EXEC/PROT_NONE from <sys/mman.h>).
 * Returns 0 on success. */
int mjs_vm_protect(unsigned char *addr, size_t length, int mprotect_flags);

/* Release a reservation made by mjs_vm_reserve. *base is NULLed on success.
 * Returns 0 on success. */
int mjs_vm_release(void **base, size_t reserved);

/* Allocate a non-moving stack: reserve `reserve` bytes, commit the top
 * `initial_commit` bytes, and paint `guard_bytes` PROT_NONE at the bottom of
 * the reservation. Success: 0, with *out_base = reservation base,
 * *out_guard_low = address of the first usable (committed) byte, and
 * *out_top = highest usable address, 16-byte aligned for ABI entry. */
int mjs_stack_alloc(size_t reserve, size_t initial_commit, size_t guard_bytes,
                    void **out_base, void **out_guard_low, size_t *out_top);

/* Free a stack allocated by mjs_stack_alloc. *base is NULLed on success.
 * Returns 0 on success. */
int mjs_stack_free(void **base);

#endif /* MOJIT0_SYS_H */