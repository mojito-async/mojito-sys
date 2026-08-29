/*
 * tests/s6/iouring/iouring_teardown.c — RED driver for issue #163.
 *
 * LINUX ONLY, AND UNEXECUTED AS WRITTEN.  Authored on macOS/arm64 where
 * mjs_iouring_create returns exactly -ENOSYS, so nothing below has run.  It
 * needs the Linux CI lane from mojito-async#141, and on Linux it also needs
 * MOJITO_IO_URING=1 plus a kernel with io_uring, which is why the issue is
 * P2 rather than P0.  This lane exits 2 (environment) rather than 0 when it
 * cannot run, so a skip is never counted as a pass.
 *
 * THE DEFECT.  native/posix/mjs_iouring.c computes the map and unmap sizes
 * with structurally DIFFERENT formulas:
 *
 *   iouring_map_rings (:332-375)  cq size = round_page(p->cq_off.cqes +
 *                                          cq_entries * sizeof(io_uring_cqe))
 *   iouring_unmap     (:197-210)  cq size = round_page(cq_entries *
 *                                          sizeof(struct io_uring_cqe) * 4u)
 *
 * The unmap path invents a `* 4` factor and drops cq_off.cqes entirely. With
 * the fixed io_uring_setup(128, ...) the kernel typically returns
 * cq_entries = 256: mapped is about 8 KiB, munmapped is 16 KiB.
 *
 * munmap over-length legally unmaps ANY mapping in the range, so closing a
 * ring can silently destroy an adjacent mapping — the sqes ring, a malloc
 * arena, or a fiber stack.  It presents as anything except itself.
 *
 * SECOND DEFECT, on the failure path.  iouring_unmap is called from
 * iouring_map_rings's OWN failure paths BEFORE u->sq_entries/cq_entries are
 * assigned (they are set at :372-374).  The recomputed sizes are therefore
 * round_page(0) == 0, munmap(ptr, 0) returns EINVAL, and every
 * already-successful mapping LEAKS.
 *
 * ORACLES.  Both are read from /proc/self/maps, so neither needs any
 * knowledge of the ring's internal addresses:
 *
 *   A. Nothing that existed before the ring was created may be gone after it
 *      is closed.  A mapping that disappears is one the ring did not create
 *      and had no business unmapping.
 *   B. Repeated create/close cycles must return the process's total mapped
 *      bytes to the baseline.  Growth is a leak.
 *
 * A guard mapping is placed immediately before the run and re-checked after,
 * which makes case A deterministic rather than dependent on whatever happens
 * to sit next to the ring.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mojito_sys.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CYCLES 16

static int failures;

static void fail(const char *what)
{
    printf("  - %s\n", what);
    failures++;
}

/* ---- /proc/self/maps helpers ------------------------------------------ */

/* Total bytes currently mapped by this process. */
static unsigned long long mapped_bytes(void)
{
    FILE *f = fopen("/proc/self/maps", "r");
    char line[512];
    unsigned long long total = 0;

    if (f == NULL)
        return 0;
    while (fgets(line, sizeof line, f) != NULL) {
        unsigned long long lo, hi;
        if (sscanf(line, "%llx-%llx", &lo, &hi) == 2)
            total += hi - lo;
    }
    fclose(f);
    return total;
}

/* 1 when [addr, addr+len) is still covered by a single mapping. */
static int still_mapped(void *addr, size_t len)
{
    FILE *f = fopen("/proc/self/maps", "r");
    char line[512];
    unsigned long long want_lo = (unsigned long long)(uintptr_t)addr;
    unsigned long long want_hi = want_lo + len;
    int found = 0;

    if (f == NULL)
        return -1;
    while (fgets(line, sizeof line, f) != NULL) {
        unsigned long long lo, hi;
        if (sscanf(line, "%llx-%llx", &lo, &hi) != 2)
            continue;
        if (lo <= want_lo && hi >= want_hi) {
            found = 1;
            break;
        }
    }
    fclose(f);
    return found;
}

/* ---- case A: closing a ring must not unmap a neighbour ---------------- */

static void case_guard_survives(void)
{
    mjs_uring *u = NULL;
    size_t guard_len = 4u * 1024u * 1024u;   /* comfortably larger than any
                                              * plausible over-unmap */
    void *guard;
    int rc;

    /* Reserve the guard FIRST, so it is one of the mappings the kernel may
     * hand back adjacent to the ring's. */
    guard = mmap(NULL, guard_len, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (guard == MAP_FAILED) {
        fail("guard: could not reserve the guard mapping");
        return;
    }
    memset(guard, 0xA5, guard_len);

    rc = mjs_iouring_create(&u);
    if (rc != 0) {
        munmap(guard, guard_len);
        fail("guard: mjs_iouring_create failed after the availability probe");
        return;
    }
    if (mjs_iouring_close(&u) != 0)
        fail("guard: mjs_iouring_close failed");

    if (still_mapped(guard, guard_len) == 0)
        fail("guard: a mapping that existed BEFORE the ring was created is"
             " gone after it was closed. iouring_unmap recomputes the cq"
             " length as round_page(cq_entries * sizeof(io_uring_cqe) * 4)"
             " while iouring_map_rings mapped round_page(cq_off.cqes +"
             " cq_entries * sizeof(io_uring_cqe)) — typically 16 KiB"
             " munmapped against 8 KiB mapped. munmap over-length legally"
             " unmaps anything in range, so ring close can destroy the sqes"
             " ring, a malloc arena, or a fiber stack.");
    else
        munmap(guard, guard_len);
}

/* ---- case B: create/close cycles must not leak address space ---------- */

static void case_no_leak(void)
{
    unsigned long long before, after;
    int i;

    /* One warm-up cycle so first-touch allocations inside the library are
     * not counted as a leak. */
    {
        mjs_uring *u = NULL;
        if (mjs_iouring_create(&u) == 0)
            mjs_iouring_close(&u);
    }

    before = mapped_bytes();
    for (i = 0; i < CYCLES; i++) {
        mjs_uring *u = NULL;
        if (mjs_iouring_create(&u) != 0) {
            fail("leak: a create failed mid-run");
            return;
        }
        if (mjs_iouring_close(&u) != 0) {
            fail("leak: a close failed mid-run");
            return;
        }
    }
    after = mapped_bytes();

    if (after > before) {
        char msg[320];
        snprintf(msg, sizeof msg,
                 "leak: %d create/close cycles grew the process's mapped"
                 " bytes from %llu to %llu (+%llu). iouring_unmap is also"
                 " called from iouring_map_rings's own failure paths BEFORE"
                 " sq_entries/cq_entries are assigned at :372-374, so the"
                 " recomputed sizes are round_page(0) == 0, munmap(ptr, 0)"
                 " returns EINVAL, and every already-successful mapping"
                 " leaks.",
                 CYCLES, before, after, after - before);
        fail(msg);
    }
}

int main(void)
{
    printf("S6 io_uring teardown (issue #163)\n");

    if (!mjs_iouring_available()) {
        printf("  io_uring backend unavailable on this host"
               " (needs Linux, a kernel with io_uring, and MOJITO_IO_URING=1).\n");
        printf("RESULT: UNSUPPORTED-PLATFORM\n");
        return 2;
    }

    case_guard_survives();
    case_no_leak();

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d RED\n", failures);
    return 1;
}
