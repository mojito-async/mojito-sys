/* mojito-sys S1 — non-moving guarded native stack allocator (issue #30).
 *
 * Implements the frozen stack services of native/include/mojito_sys.h
 * (owned by the s1/build lane):
 *
 *   int mjs_stack_alloc(size_t reserve_bytes, size_t initial_commit_bytes,
 *                       size_t guard_bytes, void **out_base,
 *                       void **out_guard_low, size_t *out_top);
 *   int mjs_stack_free(void **base);
 *
 * Layout of one reservation (the native stack grows DOWN from *out_top):
 *
 *   base                     base+guard              base+guard+usable = top
 *   | guard pages            | uncommitted span  | committed top span  |
 *   | PROT_NONE             | PROT_NONE         | PROT_READ|WRITE      |
 *   +-----------------------+-------------------+----------------------+
 *
 *   *out_base = base         *out_guard_low =        *out_top (highest
 *                            base + guard             usable, 16-aligned)
 *
 *   - The whole reservation is a SINGLE fixed mmap; addresses NEVER move
 *     for the lifetime of the region (spec 10.2: live frames must not move).
 *   - guard_bytes is rounded UP to whole pages, minimum one page; those
 *     pages are painted PROT_NONE so any overflow off the bottom of the
 *     usable range faults instead of corrupting adjacent memory.
 *   - initial_commit bytes (rounded up to pages) at the TOP of the usable
 *     range are made PROT_READ|WRITE.  The gap [base+guard, top-commit)
 *     stays PROT_NONE (reserved-only).
 *   - *out_top = highest usable address. mmap returns a page-aligned base
 *     and the total is a page multiple, so top is 16-byte-aligned — the
 *     ABI entry rule (spec 6.5 S0-T10 / AAPCS64 SP alignment).
 *   - S1 keeps the C ABI frozen: growth is NOT a new C symbol. The Mojo
 *     NativeStack.grow() wrapper pins an already-mapped PROT_NONE gap to
 *     RW in place through the frozen mjs_vm_commit service (vm lane #29),
 *     which works on any existing mmap'd region. Addresses stay put.
 *   - The full reservation is released wholesale by mjs_stack_free; the
 *     total size lives in a small base->total registry (single-thread,
 *     same as the S0 spike allocator).
 *
 * Ownership mirror: native/include/mojito_sys.h is shared with the s1/build
 * lane. This file is a client of the header's frozen declarations; it never
 * edits the header.
 */

#include "mojito_sys.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---- reservation registry ----------------------------------------------------
 * mjs_stack_free receives only the base; the munmap total comes from this
 * registry. S1 is single-thread (same limitation as the S0 spike); the
 * registry is deliberately unsynchronized. Slot reuse keeps the registry
 * bounded by the max live stack count. */

typedef struct {
    void *base;
    size_t total;
} mjs_reservation;

static mjs_reservation *g_resv;
static size_t g_resv_len, g_resv_cap;

static size_t page_size(void) {
    long ps = sysconf(_SC_PAGESIZE);
    return ps > 0 ? (size_t)ps : 4096;
}

static size_t round_up(size_t n, size_t align) {
    return (n + align - 1) / align * align;
}

int mjs_stack_alloc(
    size_t reserve_bytes,
    size_t initial_commit_bytes,
    size_t guard_bytes,
    void **out_base,
    void **out_guard_low,
    size_t *out_top)
{
    if (out_base == NULL || out_guard_low == NULL || out_top == NULL) {
        errno = EINVAL;
        return -EINVAL;
    }

    size_t ps = page_size();

    /* Guard: at least one page, rounded up to whole pages. */
    size_t guard = guard_bytes == 0 ? ps : round_up(guard_bytes, ps);

    /* Usable: at least one page, rounded up to whole pages. */
    size_t usable = round_up(reserve_bytes == 0 ? ps : reserve_bytes, ps);

    if (guard > SIZE_MAX - usable) {
        errno = EINVAL;
        return -EINVAL;
    }
    size_t total = guard + usable;

    /* Whole region PROT_NONE first: a pure reservation. */
    void *base = mmap(NULL, total, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED)
        return -errno;

    /* Commit the TOP initial_commit bytes only; never touches the guard. */
    size_t commit = round_up(initial_commit_bytes, ps);
    if (commit > usable)
        commit = usable;
    if (commit > 0) {
        size_t commit_off = total - commit; /* offset from base of RW span */
        if (mprotect((char *)base + commit_off, commit,
                     PROT_READ | PROT_WRITE) != 0) {
            int saved = errno;
            munmap(base, total);
            errno = saved;
            return -(saved != 0 ? saved : EIO);
        }
    }

    /* Record before returning so mjs_stack_free can munmap the exact total. */
    mjs_reservation *slot = NULL;
    for (size_t i = 0; i < g_resv_len; ++i) {
        if (g_resv[i].base == NULL) {
            slot = &g_resv[i];
            break;
        }
    }
    if (slot == NULL) {
        if (g_resv_len == g_resv_cap) {
            size_t cap = g_resv_cap ? g_resv_cap * 2 : 8;
            mjs_reservation *grown = realloc(g_resv, cap * sizeof *g_resv);
            if (grown == NULL) {
                munmap(base, total);
                errno = ENOMEM;
                return -ENOMEM;
            }
            g_resv = grown;
            g_resv_cap = cap;
        }
        slot = &g_resv[g_resv_len++];
    }
    slot->base = base;
    slot->total = total;

    *out_base = base;
    *out_guard_low = (char *)base + guard;
    *out_top = (size_t)((char *)base + total); /* page multiple => 16-aligned */
    return 0;
}

int mjs_stack_free(void **base) {
    if (base == NULL || *base == NULL)
        return 0; /* releasing nothing is success (double-free safe) */

    for (size_t i = 0; i < g_resv_len; ++i) {
        if (g_resv[i].base == *base) {
            int rc = munmap(*base, g_resv[i].total);
            if (rc != 0)
                return -errno;
            g_resv[i].base = NULL;
            g_resv[i].total = 0;
            *base = NULL;
            return 0;
        }
    }
    /* Address not allocated by us: refuse rather than munmap a stranger. */
    errno = EINVAL;
    return -EINVAL;
}