/* mojito-sys S1 — virtual-memory C ABI primitives (issue #29).
 *
 * Implements the frozen mjs_vm_* declarations from native/include/mojito_sys.h
 * (S1 contract, issue #24): reservation, commit, decommit, protection, and
 * release of host virtual-address ranges.
 *
 * Host: macOS arm64 (page 16384). The primitives are thin, allocation-free
 * wrappers over the common POSIX surface, so they are intentionally STATELESS
 * with respect to ownership: they operate on any mmap'd region the caller
 * already holds — a range reserved by mjs_vm_reserve, an mjs_stack_alloc
 * region, or an unrelated host mapping — and never require that the address
 * came from this module. This is what lets the stack lane's NativeStack.grow
 * commit mprotect-backed PROT_NONE gaps in place.
 *
 *   reserve:  mmap PROT_NONE MAP_PRIVATE|MAP_ANON — reserves virtual address
 *             space with no committed physical backing and no accessibility
 *             (the macOS analog of a MAP_NORESERVE reservation). No touching
 *             is performed.
 *   commit:   mprotect the range to PROT_READ|PROT_WRITE (makes pages
 *             accessible without moving them); advances *addr past the range.
 *   decommit: mprotect the range to PROT_NONE (inaccessible until
 *             re-committed; addresses preserved; physical backing released
 *             lazily via madvise(MADV_FREE) where the platform supports it);
 *             advances *addr past the range.
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
    /* Rounding to page may add one page; reject a request that would wrap. */
    if (bytes > (size_t)-1 - ps) {
        return fail(EINVAL);
    }

    size_t total = round_up(bytes == 0 ? ps : bytes, ps); /* >= 1 page */

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
    /* Set the range inaccessible first; then, best-effort, invite the VM to
     * drop physical backing. The madvise hint must not fail the operation. */
    if (mprotect(*addr, length, PROT_NONE) != 0) {
        return fail(errno);
    }
    (void)madvise(*addr, length, MADV_FREE);
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
    /* Double-release guard: a NULL base is already released. */
    if (*base == NULL) {
        return 0;
    }
    if (munmap(*base, reserved) != 0) {
        return fail(errno);
    }
    *base = NULL;
    return 0;
}