/* mojito-sys S1 — virtual-memory C ABI primitives (issue #29).
 *
 * Implements the frozen mjs_vm_* declarations from native/include/mojito_sys.h
 * (S1 contract, issue #24): reservation, commit, decommit, protection, and
 * release of host virtual-address ranges.
 *
 * Host: macOS arm64 (page 16384). The primitives are thin, allocation-free
 * wrappers over the common POSIX surface, so they are intentionally STATELESS
 * with respect to ownership: they operate on any PRIVATE ANONYMOUS mapping
 * the caller already holds — a range reserved by mjs_vm_reserve, an
 * mjs_stack_alloc region, or an unrelated private anonymous host mapping —
 * and never require that the address came from this module. Ranges backed by
 * files or shared memory must NOT be passed here: decommit re-seals pages
 * with MAP_FIXED anonymous mappings, which would silently replace file-
 * backed pages with zeros-on-read anonymous ones. This statelessness is what
 * lets the stack lane's NativeStack.grow seal PROT_NONE gaps in place.
 *
 *   reserve:  mmap PROT_NONE MAP_PRIVATE|MAP_ANON — reserves virtual address
 *             space with no committed physical backing and no accessibility
 *             (the macOS analog of a MAP_NORESERVE reservation). No touching
 *             is performed.
 *   commit:   mprotect the range to PROT_READ|PROT_WRITE (makes pages
 *             accessible without moving them); advances *addr past the range.
 *   decommit: atomically fail-closed RE-SEAL: mprotect the range to
 *             PROT_NONE, then replace it with a fresh private anonymous
 *             PROT_NONE mapping (MAP_FIXED|MAP_PRIVATE|MAP_ANON). The kernel
 *             drops all previous physical backing, so re-commit exposes
 *             ZEROES through every restoration path (commit or protect-to-
 *             RW); addresses are preserved; no lazy madvise is involved.
 *             On failure the range is left sealed PROT_NONE and *addr is
 *             untouched; advances *addr past the range on success.
 *   protect:  mprotect the range to the requested flags (PROT_* from
 *             <sys/mman.h>). Addresses are preserved.
 *   release:  returns the whole reservation to the OS; NULLs *base.
 *
 * Every entry returns 0 on success or a NEGATIVE errno on failure.
 */

#include "mojito_sys.h"

#include <sys/mman.h>
#include <unistd.h>

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* Host page size in bytes. macOS arm64 reports 16384. */
static size_t page_size(void) {
    long ps = sysconf(_SC_PAGESIZE);
    return (ps > 0) ? (size_t)ps : 16384;
}

static size_t round_up(size_t n, size_t a) {
    return (n + a - 1) / a * a;
}

static int fail(int e) {
    return -e;
}
int mjs_vm_reserve(size_t bytes, void **out_base, size_t *out_reserved) {
    if (out_base == NULL || out_reserved == NULL) {
        return fail(EINVAL);
    }

    size_t ps = page_size();
    /* Frozen ABI (issue #24): reservations round up to the ALLOCATION
     * GRANULARITY, not the page size. On POSIX they coincide, but a distinct
     * Windows granularity must not calcify into an off-by-granule bug here.
     * mjs_granularity() is defined in native/posix/mjs_page.c (issue #28);
     * fall back to the page size if it reports a bogus value. */
    int g = mjs_granularity();
    size_t gran = (g > 0 && (size_t)g >= ps) ? (size_t)g : ps;

    /* Rounding to granularity may add one granule; reject wrap-around. */
    if (bytes > (size_t)-1 - gran) {
        return fail(EINVAL);
    }

    size_t total = round_up(bytes == 0 ? gran : bytes, gran); /* >= 1 granule */

    void *base = mmap(NULL, total, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED)
        return fail(errno);

    /* Reserve keeps the range PROT_NONE; commit() later flips a sub-range to
     * PROT_READ|WRITE. Reserved size is exact; caller tracks it for release. */
    *out_base = base;
    *out_reserved = total;
    return 0;
}

int mjs_vm_commit(unsigned char **addr, size_t length) {
    if (addr == NULL || *addr == NULL) {
        return fail(EINVAL);
    }
    if (length == 0) {
        return 0; /* nothing to do; addr is not advanced */
    }
    if (mprotect(*addr, length, PROT_READ | PROT_WRITE) != 0) {
        return fail(errno);
    }
    *addr += length;
    return 0;
}

int mjs_vm_decommit(unsigned char **addr, size_t length) {
    if (addr == NULL || *addr == NULL) {
        return fail(EINVAL);
    }
    if (length == 0) {
        return 0;
    }
    /* Fail-closed re-seal (panel option D): seal PROT_NONE first, then swap
     * the range for a fresh private anonymous PROT_NONE mapping via
     * MAP_FIXED. The kernel discards all previous physical backing, so a
     * re-commit observes ZEROES through every restoration path — no lazy
     * madvise that could resurrect stale bytes. If the mmap fails the range
     * stays sealed inaccessible and the cursor is left untouched. */
    if (mprotect(*addr, length, PROT_NONE) != 0) {
        return fail(errno);
    }
    if (mmap(*addr, length, PROT_NONE,
             MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED) {
        return fail(errno); /* range sealed; cursor untouched */
    }
    *addr += length;
    return 0;
}

int mjs_vm_protect(unsigned char *addr, size_t length, int mprotect_flags) {
    if (addr == NULL) {
        return fail(EINVAL);
    }
    if (length == 0) {
        return 0;
    }
    if (mprotect(addr, length, mprotect_flags) != 0) {
        return fail(errno);
    }
    return 0;
}

int mjs_vm_release(void **base, size_t reserved) {
    if (base == NULL) {
        return fail(EINVAL);
    }
    /* Frozen ABI (issue #24): double release — an already-NULL *base — is
     * a -EINVAL error, not success. Callers that want idempotent release
     * pre-check at their layer (the Mojo wrapper does). */
    if (*base == NULL) {
        return fail(EINVAL);
    }
    if (munmap(*base, reserved) != 0) {
        return fail(errno);
    }
    *base = NULL;
    return 0;
}