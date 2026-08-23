/* S0 foundation selftest (#8): exercises the C surface of mojito_spike.h.
 *
 * Fault-probe discipline: every fault/no-fault assertion goes through
 * check_fault(), which PASSes only when the signal handlers were installed
 * successfully AND the observed outcome matches the expectation. A broken
 * harness can therefore never produce a false PASS.
 */
#include "mojito_spike.h"

#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <string.h>

static int g_checks_failed = 0;
static int g_checks_total  = 0;

#define CHECK(cond, name)                                                    \
    do {                                                                     \
        ++g_checks_total;                                                    \
        if (cond) {                                                          \
            printf("PASS: %s\n", (name));                                    \
        } else {                                                             \
            printf("FAIL: %s\n", (name));                                    \
            ++g_checks_failed;                                               \
        }                                                                    \
    } while (0)

/* --- fault probes -------------------------------------------------------- */

static sigjmp_buf g_fault_jmp;
static volatile sig_atomic_t g_faulted = 0;

static void fault_handler(int sig) {
    (void)sig;
    g_faulted = 1;
    siglongjmp(g_fault_jmp, 1);
}

static int install_fault_handlers(struct sigaction *old_segv,
                                  struct sigaction *old_bus) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, old_segv) != 0) return -1;
    if (sigaction(SIGBUS, &sa, old_bus) != 0) {
        sigaction(SIGSEGV, old_segv, NULL);
        return -1;
    }
    return 0;
}

static void restore_fault_handlers(const struct sigaction *old_segv,
                                   const struct sigaction *old_bus) {
    sigaction(SIGSEGV, old_segv, NULL);
    sigaction(SIGBUS, old_bus, NULL);
}

/* Write then read back one byte. Returns 1 if either access faulted,
 * 0 if both succeeded. Caller must have installed the handlers. */
static int probe_touch(volatile char *addr) {
    g_faulted = 0;
    if (sigsetjmp(g_fault_jmp, 1) == 0) {
        *addr = 42;
        if (*addr != 42) g_faulted = 1;
    }
    return g_faulted == 1;
}

/* expect_fault: 1 = access MUST fault, 0 = access must NOT fault. */
static void check_fault(int expect_fault, volatile char *addr,
                        const char *name) {
    ++g_checks_total;
    struct sigaction old_segv, old_bus;
    if (install_fault_handlers(&old_segv, &old_bus) != 0) {
        printf("FAIL: %s (harness: sigaction setup failed)\n", name);
        ++g_checks_failed;
        return;
    }
    int faulted = probe_touch(addr);
    restore_fault_handlers(&old_segv, &old_bus);
    if (faulted == expect_fault) {
        printf("PASS: %s\n", name);
    } else {
        printf("FAIL: %s\n", name);
        ++g_checks_failed;
    }
}

/* --- tests --------------------------------------------------------------- */

static size_t roundup_ps(size_t n, size_t ps) {
    return (n + ps - 1) / ps * ps;
}

static void test_page_size(void) {
    int ps = ms_page_size();
    CHECK(ps > 0, "ms_page_size positive");
    CHECK(ps >= 4096 && (ps & (ps - 1)) == 0,
          "ms_page_size is a power-of-two >= 4096");
}

static void test_alloc_layout(void) {
    size_t ps = (size_t)ms_page_size();
    void *base = NULL, *top = NULL;
    const size_t want = 64 * 1024;

    CHECK(ms_stack_alloc(want, &base, &top) == 0, "ms_stack_alloc succeeds");
    CHECK(base != NULL && top != NULL, "outputs are non-NULL");
    CHECK(((uintptr_t)base % ps) == 0, "base is page-aligned");

    /* guard page sits exactly at [base, base+ps) and is inaccessible */
    check_fault(1, (volatile char *)base,
                "guard page at base faults (PROT_NONE)");

    /* top = initial SP: highest usable address, 16-byte aligned */
    CHECK(((uintptr_t)top & 15u) == 0, "top is 16-byte aligned");
    CHECK((uintptr_t)top > (uintptr_t)base + ps,
          "top lies above the guard page");
    CHECK((uintptr_t)top <= (uintptr_t)base + ps + roundup_ps(want, ps),
          "top within reserved region");

    /* inverted probes: the usable region itself must be fully accessible */
    check_fault(0, (volatile char *)base + ps,
                "first usable byte (base+ps) writable and readable back");
    check_fault(0, (volatile char *)top - 1,
                "last usable byte (top-1) writable and readable back");

    CHECK(ms_stack_total_size() == ps + roundup_ps(want, ps),
          "ms_stack_total_size includes guard page");

    ms_stack_free(base);
    printf("note: freed stack base=%p\n", base);
}

static void test_nonmoving_and_multiple(void) {
    void *a_base = NULL, *a_top = NULL;
    void *b_base = NULL, *b_top = NULL;
    void *c_base = NULL, *c_top = NULL;

    CHECK(ms_stack_alloc(32 * 1024, &a_base, &a_top) == 0, "stack A alloc");
    CHECK(ms_stack_alloc(32 * 1024, &b_base, &b_top) == 0, "stack B alloc");
    CHECK(a_base != b_base, "stacks do not overlap");

    void *a_before = a_base, *a_top_before = a_top;
    CHECK(ms_stack_alloc(128 * 1024, &c_base, &c_top) == 0,
          "third alloc succeeds");
    CHECK(a_base == a_before && a_top == a_top_before,
          "existing stack unmoved by further allocations");
    CHECK(c_base != a_before && c_base != b_base,
          "reused slot does not alias live stacks");

    ms_stack_free(a_base);
    ms_stack_free(b_base);
    ms_stack_free(c_base);

    /* freeing then allocating again must succeed (no leaked reservations
     * preventing a fresh mapping) */
    void *d_base = NULL, *d_top = NULL;
    CHECK(ms_stack_alloc(48 * 1024, &d_base, &d_top) == 0,
          "alloc after free succeeds");
    ms_stack_free(d_base);
}

static void test_zero_bytes_minimum(void) {
    size_t ps = (size_t)ms_page_size();
    void *base = NULL, *top = NULL;
    CHECK(ms_stack_alloc(0, &base, &top) == 0,
          "ms_stack_alloc handles degenerate size (0 bytes)");
    CHECK(base != NULL && top != NULL, "degenerate alloc outputs non-NULL");
    CHECK(base != MAP_FAILED, "degenerate alloc is not MAP_FAILED");
    CHECK((uintptr_t)top >= (uintptr_t)base + 2 * ps,
          "top covers guard page plus minimum one usable page");
    CHECK(ms_stack_total_size() >= 2 * ps,
          "degenerate alloc still reserves guard + >=1 page");

    /* even this minimum stack has a working guard and usable region */
    check_fault(1, (volatile char *)base,
                "minimum stack: guard faults (PROT_NONE)");
    check_fault(0, (volatile char *)top - 1,
                "minimum stack: last usable byte accessible");

    ms_stack_free(base);
}

static void test_overflow_rejected(void) {
    void *base = (void *)(uintptr_t)0xdeadbeef;
    void *top  = (void *)(uintptr_t)0xdeadbeef;

    CHECK(ms_stack_alloc(SIZE_MAX, &base, &top) == -1,
          "SIZE_MAX request rejected with -1");
    CHECK(errno == EINVAL, "SIZE_MAX rejection sets EINVAL");
    CHECK(base == (void *)(uintptr_t)0xdeadbeef &&
              top == (void *)(uintptr_t)0xdeadbeef,
          "rejected request leaves outputs untouched");

    CHECK(ms_stack_alloc(SIZE_MAX / 2 + 1, &base, &top) == -1,
          "near-SIZE_MAX request (would overflow rounding) rejected");

    /* allocator still healthy afterwards */
    CHECK(ms_stack_alloc(16 * 1024, &base, &top) == 0,
          "alloc succeeds again after rejected requests");
    ms_stack_free(base);
}

int main(void) {
    test_page_size();
    test_alloc_layout();
    test_nonmoving_and_multiple();
    test_zero_bytes_minimum();
    test_overflow_rejected();

    printf("%d/%d checks passed\n", g_checks_total - g_checks_failed,
           g_checks_total);
    return g_checks_failed == 0 ? 0 : 1;
}
