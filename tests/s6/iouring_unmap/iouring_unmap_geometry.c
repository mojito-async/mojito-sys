/*
 * tests/s6/iouring_unmap/iouring_unmap_geometry.c — RED driver for #169.
 *
 * THE DEFECT.  native/posix/mjs_iouring.c maps three regions at ring create
 * and unmaps them at ring close, and the two sides compute their lengths
 * from STRUCTURALLY DIFFERENT formulas.  The mapped length is never stored.
 *
 *   iouring_map_rings  :350-392   lengths from the offsets the KERNEL
 *                                 returned: p->sq_off.array, p->cq_off.cqes
 *   iouring_unmap      :334-347   lengths from `entries * elemsize * 4`,
 *                                 which uses neither offset and invents a
 *                                 `* 4` factor found nowhere in the map path
 *
 *   mapping    mmap length                          munmap length
 *   sq_ring    round_page(sq_off.array + n*4)       round_page(n*4*4)
 *   cq_ring    round_page(cq_off.cqes  + m*16)      round_page(m*16*4)
 *   sqes       round_page(n*sizeof(sqe))            same expression -- correct
 *
 * `sqes` is right for exactly one reason: it is the SAME EXPRESSION on both
 * sides.  That is the tell.  The other two were guessed at, and nothing in
 * the file forces them to agree.
 *
 * WHY THE OBVIOUS ORACLES CANNOT SEE IT.  On a 4 KiB-page host sq is
 * under-unmapped by a page and cq is over-unmapped by two, and Linux hands
 * out mmap(NULL, ...) top-down so cq_ring + cq_map_len == sq_ring exactly.
 * The cq overshoot therefore consumes the page the short sq teardown left
 * behind, and RESIDUAL MAPPED BYTES AFTER CLOSE ARE ZERO.  A /proc/self/maps
 * diff sees a clean teardown.  A byte-total leak check sees nothing.  Both
 * of issue #163's oracles pass on this code.  So this lane does not measure
 * the aggregate effect; it measures THE CALLS, comparing each munmap length
 * against its own mmap length.
 *
 * WHY munmap NEVER COMPLAINS.  POSIX and Linux both specify that munmap does
 * not fail on a range containing unmapped pages: it releases whatever is
 * mapped in the range and returns 0.  The cq overshoot is silent by design
 * of the syscall.  "It currently lands on our own sq mapping" is the
 * placement mmap(NULL, ...) happened to pick, not a guarantee, which is what
 * makes this a latent corruption primitive rather than an accounting error.
 *
 * PAGE SIZE MATTERS AND IS NOT ASSUMED.  At 16K and 64K pages every one of
 * these regions rounds up to a single page and the two formulas coincide by
 * accident, so the defect vanishes.  This lane derives the geometry from the
 * kernel at run time, prints the page size it observed, and REFUSES A
 * VERDICT (exit 2) on a page size where the formulas cannot disagree.  A
 * green row from such a host would be worthless and must not be mistakable
 * for evidence.
 *
 * HOW IT OBSERVES THE CALLS.  mmap and munmap are interposed by DEFINING
 * them in this executable: the executable's definitions come first in the
 * dynamic linker's global lookup scope, so libmojito_sys.so's calls resolve
 * here (run.sh links with -rdynamic).  Pass-through is a direct syscall
 * rather than dlsym(RTLD_NEXT), which would need an allocator that may
 * itself call mmap.  Only mappings that carry an io_uring ring offset with
 * MAP_SHARED on a real fd, while recording is armed, are touched; everything
 * else goes straight through.
 *
 * t2 AND THE GUARD.  The address immediately above cq_ring is already
 * occupied by sq_ring, so MAP_FIXED_NOREPLACE there fails EEXIST; and the
 * ring cannot be relocated, because io_uring_get_unmapped_area rejects any
 * caller-supplied address (MAP_FIXED and even a plain hint return EINVAL,
 * measured).  So the gap is CREATED instead: from inside the mmap
 * interposer, after the SQ ring is mapped and before the CQ ring is, a
 * one-page anonymous mapping is placed.  Top-down placement puts it directly
 * below sq_ring, so the cq ring lands directly below IT and
 * cq_ring + cq_map_len == guard.  The guard belongs to this process and the
 * ring did not create it, so if closing the ring destroys it, teardown
 * demonstrably unmaps address space it does not own.  Adjacency is verified,
 * not assumed; if it does not hold, t2 reports INCONCLUSIVE rather than a
 * verdict.
 *
 * t3 AND THE FAILURE PATHS (the second half of #169).  iouring_unmap is
 * called from inside iouring_map_rings at :369 and :378, but u->sq_entries
 * and u->cq_entries are only assigned at :390-391, AFTER both call sites.
 * u is calloc'd (:413), so both are 0, every length is round_page(0) == 0,
 * munmap(addr, 0) fails EINVAL, and the return value is ignored.  Nothing is
 * released.  This lane fails the 2nd and then the 3rd ring mmap from the
 * interposer and checks that the mappings made before the failure are gone.
 *
 * ENVIRONMENT GUARD.  Needs a NATIVE Linux kernel with io_uring.  Under
 * Rosetta / qemu linux/amd64 emulation io_uring_setup returns ENOSYS, and
 * Docker's default seccomp profile refuses the syscall too.  In either case
 * this lane exits 2 (UNSUPPORTED-PLATFORM), never 0 and never 1: "I could
 * not measure" must never be recorded as "nothing wrong"
 * (mojito-async#141).
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>

#if !defined(__linux__)

/* Detect-and-exclude, mirroring the backend itself: on every non-Linux host
 * there is no io_uring to measure and this lane is an environment result. */
int main(void)
{
    printf("S6 io_uring unmap geometry (issue #169)\n");
    printf("  not Linux: io_uring does not exist on this host.\n");
    printf("RESULT: UNSUPPORTED-PLATFORM\n");
    return 2;
}

#else /* __linux__ */

#include "mojito_sys.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <linux/io_uring.h>

/* ---- pass-through, allocation-free ------------------------------------
 * syscall() returns -1 with errno set on failure, and (void *)-1 is
 * MAP_FAILED, so both wrappers can return the raw result unchanged. */

static void *real_mmap(void *addr, size_t len, int prot, int flags, int fd,
                       off_t off)
{
    return (void *)syscall(SYS_mmap, addr, len, prot, flags, fd, off);
}

static int real_munmap(void *addr, size_t len)
{
    return (int)syscall(SYS_munmap, addr, len);
}

/* ---- recorded ring mappings ------------------------------------------- */

#define MAX_MAPS 8

struct ringmap {
    void *addr;
    size_t map_len;
    unsigned long long off;
    const char *name;
    int unmap_seen;
    size_t unmap_len;
    int unmap_rc;
    int unmap_errno;
};

static struct ringmap maps[MAX_MAPS];
static int nmaps;

static int recording;        /* arm the interposer */
static int ring_mmap_index;  /* 0 = sq_ring, 1 = cq_ring, 2 = sqes */
static int fail_at = -1;     /* fail this ring mmap; -1 = none */
static int guard_enabled;
static void *guard_addr;
static size_t page_len;

static const char *offset_name(unsigned long long off)
{
    if (off == IORING_OFF_SQ_RING)
        return "sq_ring";
    if (off == IORING_OFF_CQ_RING)
        return "cq_ring";
    if (off == IORING_OFF_SQES)
        return "sqes";
    return "?";
}

static int is_ring_offset(unsigned long long off)
{
    return off == IORING_OFF_SQ_RING || off == IORING_OFF_CQ_RING ||
           off == IORING_OFF_SQES;
}

/* THE INTERPOSERS.  Only io_uring ring mappings made while recording is
 * armed are observed; everything else in the process (the allocator
 * included) passes straight through untouched. */

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    void *p;

    if (!recording || fd < 0 || !(flags & MAP_SHARED) ||
        !is_ring_offset((unsigned long long)off))
        return real_mmap(addr, len, prot, flags, fd, off);

    if (fail_at == ring_mmap_index) {
        ring_mmap_index++;
        errno = ENOMEM;
        return MAP_FAILED;
    }
    ring_mmap_index++;

    p = real_mmap(addr, len, prot, flags, fd, off);
    if (p == MAP_FAILED)
        return p;

    if (nmaps < MAX_MAPS) {
        maps[nmaps].addr = p;
        maps[nmaps].map_len = len;
        maps[nmaps].off = (unsigned long long)off;
        maps[nmaps].name = offset_name((unsigned long long)off);
        nmaps++;
    }

    /* t2: create the gap the guard needs, between the SQ and CQ maps. */
    if (guard_enabled && (unsigned long long)off == IORING_OFF_SQ_RING &&
        guard_addr == NULL) {
        void *g = real_mmap(NULL, page_len, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (g != MAP_FAILED) {
            guard_addr = g;
            *(volatile uint32_t *)g = 0xA5A5A5A5u;
        }
    }
    return p;
}

int munmap(void *addr, size_t len)
{
    int rc;
    int saved;
    int i;

    rc = real_munmap(addr, len);
    saved = errno;
    if (recording) {
        for (i = 0; i < nmaps; i++) {
            if (maps[i].addr == addr && !maps[i].unmap_seen) {
                maps[i].unmap_seen = 1;
                maps[i].unmap_len = len;
                maps[i].unmap_rc = rc;
                maps[i].unmap_errno = (rc != 0) ? saved : 0;
                break;
            }
        }
    }
    errno = saved;
    return rc;
}

/* Is the page at `a` mapped? mincore reports ENOMEM for an unmapped range
 * and does not touch the contents, so it is safe on a page we must not
 * fault. */
static int still_mapped(void *a)
{
    unsigned char vec[1];

    if (a == NULL)
        return 0;
    return mincore(a, page_len, vec) == 0;
}

static void reset_recorder(void)
{
    memset(maps, 0, sizeof maps);
    nmaps = 0;
    ring_mmap_index = 0;
    fail_at = -1;
    guard_enabled = 0;
    guard_addr = NULL;
}

static struct ringmap *find_map(const char *name)
{
    int i;

    for (i = 0; i < nmaps; i++)
        if (strcmp(maps[i].name, name) == 0)
            return &maps[i];
    return NULL;
}

/* ---- verdict bookkeeping ---------------------------------------------- */

static int failures;
static int inconclusive_page_size;

static void fail(const char *what)
{
    printf("  - %s\n", what);
    failures++;
}

/* ---- geometry, read from the kernel rather than assumed ---------------- */

static size_t round_page(size_t n, size_t page)
{
    return (n + page - 1u) & ~(page - 1u);
}

static int formulas_can_disagree; /* at THIS page size, for THIS geometry */

static int report_geometry(void)
{
    struct io_uring_params p;
    long r;
    int fd;
    size_t sq_map, sq_un, cq_map, cq_un, se_map;

    memset(&p, 0, sizeof p);
    r = syscall(__NR_io_uring_setup, 128u, &p); /* same entries as the backend */
    if (r < 0) {
        printf("  io_uring_setup(128): %s\n", strerror(errno));
        return -1;
    }
    fd = (int)r;

    sq_map = round_page((size_t)p.sq_off.array +
                        (size_t)p.sq_entries * sizeof(uint32_t), page_len);
    sq_un = round_page((size_t)p.sq_entries * sizeof(uint32_t) * 4u, page_len);
    cq_map = round_page((size_t)p.cq_off.cqes +
                        (size_t)p.cq_entries * sizeof(struct io_uring_cqe),
                        page_len);
    cq_un = round_page((size_t)p.cq_entries * sizeof(struct io_uring_cqe) * 4u,
                       page_len);
    se_map = round_page((size_t)p.sq_entries * sizeof(struct io_uring_sqe),
                        page_len);

    printf("  geometry: sq_entries=%u cq_entries=%u sq_off.array=%u"
           " cq_off.cqes=%u\n", p.sq_entries, p.cq_entries, p.sq_off.array,
           p.cq_off.cqes);
    printf("  features=0x%08x SINGLE_MMAP=%s (checked: the separate CQ map is"
           " an alias of the same kernel object, so the double map is"
           " redundant, not wrong)\n", p.features,
           (p.features & IORING_FEAT_SINGLE_MMAP) ? "yes" : "no");
    printf("  formulas at page=%zu:  sq map=%zu unmap=%zu | cq map=%zu"
           " unmap=%zu | sqes map=%zu unmap=%zu\n",
           page_len, sq_map, sq_un, cq_map, cq_un, se_map, se_map);

    formulas_can_disagree = (sq_map != sq_un) || (cq_map != cq_un);
    close(fd);
    return 0;
}

/* ---- t1: every munmap length must equal its own mmap length ----------- */

static void t1_lengths_match(void)
{
    mjs_uring *u = NULL;
    int rc;
    int i;

    reset_recorder();
    guard_enabled = 1;
    recording = 1;
    rc = mjs_iouring_create(&u);
    if (rc != 0 || u == NULL) {
        recording = 0;
        printf("  t1 mjs_iouring_create rc=%d\n", rc);
        fail("t1 lengths: BLOCKED, could not create a ring to measure");
        return;
    }

    printf("  t1 mappings made by iouring_map_rings:\n");
    for (i = 0; i < nmaps; i++)
        printf("      %-8s %p .. %p  mmap len %zu\n", maps[i].name,
               maps[i].addr, (void *)((char *)maps[i].addr + maps[i].map_len),
               maps[i].map_len);
    if (guard_addr != NULL)
        printf("      %-8s %p .. %p  (this process's own page, placed between"
               " the sq and cq maps)\n", "guard", guard_addr,
               (void *)((char *)guard_addr + page_len));

    rc = mjs_iouring_close(&u);
    recording = 0;
    printf("  t1 mjs_iouring_close rc=%d\n", rc);

    printf("  t1 munmap calls observed:\n");
    for (i = 0; i < nmaps; i++) {
        if (!maps[i].unmap_seen) {
            printf("      %-8s NEVER UNMAPPED\n", maps[i].name);
            continue;
        }
        printf("      %-8s munmap(%p, %zu) rc=%d%s   mmap len was %zu   %s\n",
               maps[i].name, maps[i].addr, maps[i].unmap_len,
               maps[i].unmap_rc,
               maps[i].unmap_rc != 0 ? " ERRNO" : "",
               maps[i].map_len,
               maps[i].unmap_len == maps[i].map_len ? "match"
                   : (maps[i].unmap_len < maps[i].map_len
                          ? "SHORT (leaks the remainder)"
                          : "OVERSHOOT (unmaps memory it does not own)"));
    }

    for (i = 0; i < nmaps; i++) {
        char msg[768];

        if (!maps[i].unmap_seen) {
            snprintf(msg, sizeof msg,
                     "t1 lengths: the %s mapping was never unmapped at all",
                     maps[i].name);
            fail(msg);
            continue;
        }
        if (maps[i].unmap_len == maps[i].map_len)
            continue;
        snprintf(msg, sizeof msg,
                 "t1 lengths: %s was mapped with %zu bytes and unmapped with"
                 " %zu (%s%zu). iouring_unmap (:334-347) recomputes the length"
                 " from `entries * elemsize * 4` while iouring_map_rings"
                 " (:350-392) derives it from the kernel's own"
                 " %s. Two formulas 40 lines apart with nothing forcing them"
                 " to agree, and the mapped length is never stored.",
                 maps[i].name, maps[i].map_len, maps[i].unmap_len,
                 maps[i].unmap_len < maps[i].map_len ? "short by " : "over by ",
                 maps[i].unmap_len < maps[i].map_len
                     ? maps[i].map_len - maps[i].unmap_len
                     : maps[i].unmap_len - maps[i].map_len,
                 maps[i].off == IORING_OFF_SQ_RING ? "sq_off.array"
                                                   : "cq_off.cqes");
        fail(msg);
    }
}

/* ---- t2: the guard mapping must survive the ring's teardown ----------- */

static void t2_guard_survives(void)
{
    struct ringmap *cq = find_map("cq_ring");
    int adjacent;

    if (guard_addr == NULL || cq == NULL) {
        printf("  t2 guard: INCONCLUSIVE, no guard page was placed\n");
        return;
    }

    adjacent = ((char *)cq->addr + cq->map_len) == (char *)guard_addr;
    printf("  t2 guard: cq_ring + cq_map_len = %p, guard = %p -> %s\n",
           (void *)((char *)cq->addr + cq->map_len), guard_addr,
           adjacent ? "adjacent, inside the overshoot range"
                    : "NOT adjacent");
    if (!adjacent) {
        printf("  t2 guard: INCONCLUSIVE, the kernel did not place the guard"
               " immediately above the cq ring, so the overshoot cannot be"
               " observed through it. t1 is unaffected.\n");
        return;
    }

    printf("  t2 guard: mapped after the ring closed? %s\n",
           still_mapped(guard_addr) ? "yes" : "NO");
    if (!still_mapped(guard_addr)) {
        char msg[768];

        snprintf(msg, sizeof msg,
                 "t2 guard: closing the ring destroyed a one-page anonymous"
                 " mapping at %p that this process owns and the ring never"
                 " created. munmap(cq_ring, %zu) covers %p .. %p while the cq"
                 " mapping is only %zu bytes, and munmap does not fail on a"
                 " range containing pages it does not own, so the overshoot"
                 " is silent. Today the sq ring usually occupies that range,"
                 " which is unspecified mmap(NULL, ...) placement and not a"
                 " guarantee; anything else that lands there (a malloc arena,"
                 " a fiber stack) is unmapped underneath live code.",
                 guard_addr, cq->unmap_len, cq->addr,
                 (void *)((char *)cq->addr + cq->unmap_len), cq->map_len);
        fail(msg);
        guard_addr = NULL; /* already gone; nothing to release */
    } else {
        recording = 0;
        real_munmap(guard_addr, page_len);
        guard_addr = NULL;
    }
}

/* ---- t3: the map-failure paths must release what they already mapped -- */

static void t3_failure_path(int fail_index, const char *what,
                            const char *expected_leaks)
{
    mjs_uring *u = NULL;
    int rc;
    int i;
    int leaked = 0;

    reset_recorder();
    fail_at = fail_index;
    recording = 1;
    rc = mjs_iouring_create(&u);
    recording = 0;

    printf("  t3 %s: mjs_iouring_create rc=%d (%s), %d mapping(s) made before"
           " the failure\n", what, rc, rc < 0 ? strerror(-rc) : "?", nmaps);

    if (rc >= 0) {
        char msg[256];

        snprintf(msg, sizeof msg,
                 "t3 %s: create returned %d after the %s mmap was forced to"
                 " fail; it must return a negative errno", what, rc, what);
        fail(msg);
        if (u != NULL)
            mjs_iouring_close(&u);
        return;
    }

    for (i = 0; i < nmaps; i++) {
        int mapped = still_mapped(maps[i].addr);

        printf("      %-8s %p len %zu  munmap %s  -> %s\n", maps[i].name,
               maps[i].addr, maps[i].map_len,
               maps[i].unmap_seen ? "called" : "NOT CALLED",
               mapped ? "STILL MAPPED (leaked)" : "released");
        if (maps[i].unmap_seen && maps[i].unmap_rc != 0)
            printf("               munmap(%p, %zu) failed: %s\n",
                   maps[i].addr, maps[i].unmap_len,
                   strerror(maps[i].unmap_errno));
        if (mapped) {
            leaked++;
            real_munmap(maps[i].addr, maps[i].map_len); /* keep the process clean */
        }
    }

    if (leaked != 0) {
        char msg[640];

        snprintf(msg, sizeof msg,
                 "t3 %s: %d mapping(s) leaked (%s). iouring_unmap is called"
                 " from inside iouring_map_rings at :369 and :378, but"
                 " u->sq_entries and u->cq_entries are assigned at :390-391,"
                 " AFTER both call sites. u is calloc'd at :413 so both are 0,"
                 " every recomputed length is round_page(0) == 0,"
                 " munmap(addr, 0) fails EINVAL, and iouring_unmap ignores"
                 " every return value. The ring fd is then closed and the"
                 " handle freed, so the address space is unreachable and"
                 " leaked for the life of the process.",
                 what, leaked, expected_leaks);
        fail(msg);
    }
}

int main(void)
{
    struct utsname un;

    printf("S6 io_uring unmap geometry and map-failure teardown (issue #169)\n");

    if (uname(&un) == 0)
        printf("  host: %s %s %s\n", un.sysname, un.release, un.machine);

    page_len = (size_t)sysconf(_SC_PAGESIZE);
    printf("  page size observed: %zu\n", page_len);

    /* Environment guard, BEFORE the capability flag is set: probe() is host
     * kernel support alone. Rosetta/qemu linux/amd64 and Docker's default
     * seccomp profile both make io_uring_setup return ENOSYS, and a lane
     * that cannot issue the syscall must report that, not a verdict. */
    if (!mjs_iouring_probe()) {
        printf("  mjs_iouring_probe() == 0: this kernel cannot create an"
               " io_uring.\n");
        printf("  Needs a NATIVE Linux kernel with io_uring. Emulated"
               " linux/amd64 (Rosetta/qemu) and Docker's default seccomp"
               " profile both fail io_uring_setup with ENOSYS.\n");
        printf("RESULT: UNSUPPORTED-PLATFORM\n");
        return 2;
    }

    setenv("MOJITO_IO_URING", "1", 1);
    if (!mjs_iouring_available()) {
        printf("  mjs_iouring_available() == 0 with MOJITO_IO_URING=1 set and"
               " mjs_iouring_probe() == 1.\n");
        printf("RESULT: ENVIRONMENT\n");
        return 2;
    }

    if (report_geometry() != 0) {
        printf("RESULT: ENVIRONMENT\n");
        return 2;
    }

    /* The interposer must actually be reached, or every case below would
     * pass vacuously. Proven by t1 recording three mappings. */
    t1_lengths_match();
    t2_guard_survives();
    if (nmaps == 0) {
        printf("  the mmap interposer observed NOTHING: the lane cannot"
               " measure anything and must not report a verdict.\n");
        printf("RESULT: ENVIRONMENT\n");
        return 2;
    }

    t3_failure_path(1, "cq_ring", "the sq ring");
    t3_failure_path(2, "sqes", "the sq and cq rings");

    if (!formulas_can_disagree) {
        inconclusive_page_size = 1;
        printf("\n  At page size %zu every ring region rounds up to a single"
               " page, so the map and unmap formulas produce identical"
               " numbers and t1/t2 CANNOT distinguish correct code from the"
               " defect. This is not a pass.\n", page_len);
        printf("RESULT: INCONCLUSIVE-PAGE-SIZE\n");
        return 2;
    }
    (void)inconclusive_page_size;

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d RED\n", failures);
    return 1;
}

#endif /* __linux__ */
