#ifndef MOJITO_SYS_H
#define MOJITO_SYS_H

#include <stddef.h>

/*
 * mojito-sys S1 — frozen C ABI (issue #24): page / VM / stack services.
 *
 * S1 contract:
 *   - Live stack addresses never move. Once a stack region is allocated and
 *     committed, its usable range is stable for the lifetime of the binding;
 *     mjs_stack_free returns it wholesale. (No stack growth/shrink in S1.)
 *   - Every stack region carries guard_bytes (a POSITIVE page multiple) of
 *     PROT_NONE at the LOW end of the reservation (below *out_guard_low).
 *     Crossing it is a hard fault by design. guard_bytes == 0 or a non-page
 *     multiple is an error (-EINVAL).
 *   - Compatibility: the signatures and semantics below are frozen for the
 *     S1 milestone. Extending the ABI means adding new names, never changing
 *     these declarations. The ABI version is MOJITO_SYS_ABI_VERSION.
 *   - mjs_page_size / mjs_granularity are informational. Byte counts passed
 *     to commit/decommit/protect must be positive page multiples by the
 *     caller (validated where cheap; undefined results otherwise).
 *   - Concurrency: these primitives are NOT thread-safe on a shared region.
 *     A reservation/stack region is single-owner; serialize concurrent use
 *     of the same region (or its cursor) by the caller.
 *
 * Return-value contract (all entry points):
 *   0 == success; negative == -errno (e.g. -ENOMEM, -EINVAL, -EFAULT).
 *   Out-parameters are UNTOUCHED on failure.
 */

#define MOJITO_SYS_ABI_VERSION 1

/* Protection flags, opaque at this boundary. Map 1:1 to POSIX PROT_* today;
 * the Mojo layer translates to platform-specific bits. */
#define MJS_PROT_NONE  0x00
#define MJS_PROT_READ  0x01
#define MJS_PROT_WRITE 0x02
#define MJS_PROT_EXEC  0x04

#ifdef __cplusplus
extern "C" {
#endif

/* Host page size (sysconf(_SC_PAGESIZE)); > 0. */
int mjs_page_size(void);

/* Allocation granularity for reservations; >= page size. */
int mjs_granularity(void);

/* ABI version of this library. Consumers that dynload the dylib SHOULD
 * call this and reject MOJITO_SYS_ABI_VERSION mismatches. */
int mjs_abi_version(void);

/* Reserve `bytes` (rounded up to granularity) of address space without
 * committing physical memory (mmap NORESERVE-equivalent). On success returns
 * 0, stores the reservation base in *out_base and the exact reserved size in
 * *out_reserved. */
int mjs_vm_reserve(size_t bytes, void **out_base, size_t *out_reserved);

/* Make `length` bytes at *addr accessible (back the pages; the POSIX
 * mechanism is mprotect/mmap-modifying; NOT mlock: no physical-frame
 * pinning). `length` must be a positive page multiple.
 * On full success *addr advances to the first byte past the committed range.
 * On failure *addr is unchanged (atomic: 0-or-length). The implementation
 * does not validate the range against any reservation — the caller owns the
 * cursor and must keep it inside a live reservation. */
int mjs_vm_commit(unsigned char **addr, size_t length);

/* Make `length` bytes at *addr inaccessible/zero-fill until re-committed.
 * `length` must be a positive page multiple. Same cursor contract as
 * mjs_vm_commit: *addr advances only on full success. */
int mjs_vm_decommit(unsigned char **addr, size_t length);

/* Change protection of `length` bytes at *addr to protection (an OR of
 * MJS_PROT_READ/MJS_PROT_WRITE/MJS_PROT_EXEC, or MJS_PROT_NONE). Returns 0
 * on success. */
int mjs_vm_protect(unsigned char *addr, size_t length, int protection);

/* Release a reservation made by mjs_vm_reserve. *base is NULLed on success.
 * Double-release (already-NULL *base) is a -EINVAL error. Returns 0 on
 * success. */
int mjs_vm_release(void **base, size_t reserved);

/* Allocate a non-moving stack: reserve `reserve` bytes, paint `guard_bytes`
 * (positive page multiple) PROT_NONE at the bottom, and commit the top
 * `initial_commit` bytes of the usable range. Success: 0, with
 * *out_base = reservation base, *out_guard_low = address of the first
 * usable byte, and *out_top = highest usable address, 16-byte aligned for
 * ABI entry. */
int mjs_stack_alloc(size_t reserve, size_t initial_commit, size_t guard_bytes,
                    void **out_base, void **out_guard_low, size_t *out_top);

/* Free a stack allocated by mjs_stack_alloc (whole reservation).
 * *base is NULLed on success. Returns 0 on success. */
int mjs_stack_free(void **base);

#ifdef __cplusplus
}
#endif

#endif /* MOJITO_SYS_H */
