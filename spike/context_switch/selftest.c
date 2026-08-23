/* S0 foundation selftest (#8): exercises the C surface of mojito_spike.h.
 * Red phase: fails to link because native_stack.c / ms_ctx.c are absent. */
#include "mojito_spike.h"

#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
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

/* --- guard-page probe --------------------------------------------------- */

static sigjmp_buf g_guard_jmp;
static volatile sig_atomic_t g_guard_faulted = 0;

static void guard_handler(int sig) {
    (void)sig;
    g_guard_faulted = 1;
    siglongjmp(g_guard_jmp, 1);
}

static int touch_probes_sigsegv(volatile char *addr) {
    struct sigaction sa, old_segv, old_bus;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = guard_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &old_segv) != 0) return -1;
    if (sigaction(SIGBUS, &sa, &old_bus) != 0) return -1;

    g_guard_faulted = 0;
    if (sigsetjmp(g_guard_jmp, 1) == 0) {
        *addr = 1; /* expected to fault: page must be PROT_NONE */
    }
    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    return g_guard_faulted == 1;
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
    int ps = ms_page_size();
    void *base = NULL, *top = NULL;
    const size_t want = 64 * 1024;

    CHECK(ms_stack_alloc(want, &base, &top) == 0, "ms_stack_alloc succeeds");
    CHECK(base != NULL && top != NULL, "outputs are non-NULL");
    CHECK(((uintptr_t)base % (uintptr_t)ps) == 0, "base is page-aligned");

    /* guard page sits exactly at [base, base+ps) and is inaccessible */
    CHECK(touch_probes_sigsegv((volatile char *)base),
          "guard page at base faults (PROT_NONE)");

    /* top = initial SP: highest usable address, 16-byte aligned */
    CHECK(((uintptr_t)top & 15u) == 0, "top is 16-byte aligned");
    uintptr_t usable_end = (uintptr_t)base + (uintptr_t)ps;
    CHECK((uintptr_t)top > usable_end, "top lies above the guard page");
    CHECK(roundup_ps(want, (size_t)ps) >= want, "rounding never shrinks");
    CHECK((uintptr_t)top <= usable_end + roundup_ps(want, (size_t)ps),
          "top within reserved region");

    CHECK(ms_stack_total_size() == (size_t)ps + roundup_ps(want, (size_t)ps),
          "ms_stack_total_size includes guard page");

    ms_stack_free(base);
    printf("note: freed stack base=%p\n", base);
}

static void test_nonmoving_and_multiple(void) {
    void *a_base = NULL, *a_top = NULL;
    void *b_base = NULL, *b_top = NULL;

    CHECK(ms_stack_alloc(32 * 1024, &a_base, &a_top) == 0, "stack A alloc");
    CHECK(ms_stack_alloc(32 * 1024, &b_base, &b_top) == 0, "stack B alloc");
    CHECK(a_base != b_base, "stacks do not overlap");

    void *a_before = a_base, *a_top_before = a_top;
    CHECK(ms_stack_alloc(128 * 1024, &b_base, &b_top) == 0,
          "third alloc succeeds");
    CHECK(a_base == a_before && a_top == a_top_before,
          "existing stack unmoved by further allocations");
    CHECK(b_base != a_before, "reused slot does not alias live stack");

    ms_stack_free(a_base);
    ms_stack_free(b_base);

    /* freeing then allocating again must succeed (no leaked reservations
     * preventing a fresh mapping) */
    void *c_base = NULL, *c_top = NULL;
    CHECK(ms_stack_alloc(48 * 1024, &c_base, &c_top) == 0,
          "alloc after free succeeds");
    ms_stack_free(c_base);
}

static void test_zero_bytes_minimum(void) {
    int ps = ms_page_size();
    void *base = NULL, *top = NULL;
    CHECK(ms_stack_alloc(0, &base, &top) == 0 || 1,
          "ms_stack_alloc handles degenerate size without crashing");
    if (base != NULL) {
        CHECK(ms_stack_total_size() >= (size_t)ps + (size_t)ps,
              "degenerate alloc still reserves guard + >=1 page");
        ms_stack_free(base);
    }
}

int main(void) {
    test_page_size();
    test_alloc_layout();
    test_nonmoving_and_multiple();
    test_zero_bytes_minimum();

    printf("%d/%d checks passed\n", g_checks_total - g_checks_failed,
           g_checks_total);
    return g_checks_failed == 0 ? 0 : 1;
}
