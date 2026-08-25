/*
 * s1_stack_probe.c — memory-stack lane probe (issue #30).
 *
 * Links into the stack_test driver executable. Resolves the frozen
 * libmojito_sys.dylib symbols at runtime via dlopen/dlsym so that a missing
 * implementation yields a deterministic RED verdict from the Mojo driver
 * instead of a load failure.
 *
 * Exported:
 *   int s1_stack_probe_init(void);     0 = all required symbols resolved
 *   int s1_guard_probe_run(void);      verdict code (0 = pass)
 *   int s1_contract_probe_run(void);   # failed checks (0 = pass)
 * Verdict codes from s1_guard_probe_run:
 *   0  controlled fault in child + healthy top-of-stack write in parent
 *   2  child exited normally (guard absent or writable => silent corruption)
 *   3  child died from some other unexpected signal
 *   4  stack allocation failed
 *   5  waitpid failed
 *
 * Semantics verified (matches the geometry the Mojo driver asserts too):
 *   1. The single highest usable byte of a freshly allocated guarded stack
 *      is writable in the parent (no false boundary faults).
 *   2. A forked child deliberately writing into the reserved PROT_NONE guard
 *      region dies from a synchronous hardware fault — SIGBUS on macOS
 *      arm64 for an access to an existing PROT_NONE page, SIGSEGV elsewhere.
 *      Either means overflow faults immediately and stays contained.
 *
 * The probe allocates a stack itself through the same ABI so the driver
 * does not need the exact byte counts here; the geometry contract (guard
 * at [base, base+guard)) is asserted from the mojo side as well.
 */

#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

typedef int (*mjs_stack_alloc_fn)(size_t, size_t, size_t, void **, void **,
                                  size_t *);
typedef int (*mjs_stack_free_fn)(void **);

static mjs_stack_alloc_fn p_alloc;
static mjs_stack_free_fn p_free;

int s1_stack_probe_init(void)
{
    void *h = dlopen("libmojito_sys.dylib", RTLD_NOW | RTLD_GLOBAL);
    if (h == NULL)
        return 1;
    p_alloc = (mjs_stack_alloc_fn)dlsym(RTLD_DEFAULT, "mjs_stack_alloc");
    p_free = (mjs_stack_free_fn)dlsym(RTLD_DEFAULT, "mjs_stack_free");
    if (p_alloc == NULL || p_free == NULL)
        return 1;
    return 0;
}

int s1_guard_probe_run(void)
{
    if (p_alloc == NULL || p_free == NULL)
        return 4;

    void *base = NULL, *guard_low = NULL;
    size_t top = 0;
    if (p_alloc(256 * 1024, 16 * 1024, 16384, &base, &guard_low, &top) != 0)
        return 4;
    if (base == NULL || guard_low == NULL || top == 0) {
        p_free(&base);
        return 4;
    }

    /* Parent sanity: highest usable byte writable. */
    volatile char *top_byte = (volatile char *)(uintptr_t)top - 1;
    *top_byte = 42;

    /* Guard region: [base, guard_low). */
    if (guard_low <= base) {
        p_free(&base);
        return 4;
    }

    pid_t pid = fork();
    if (pid < 0) {
        p_free(&base);
        return 5;
    }
    if (pid == 0) {
        /* Detach from any runtime-installed fault handlers so the deliberate
         * fault takes the platform default action. */
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        /* Write into the middle of the guard region: MUST fault. */
        volatile char *guard = (volatile char *)(uintptr_t)base +
                               ((uintptr_t)guard_low - (uintptr_t)base) / 2;
        *guard = 7;
        _exit(0); /* reached => guard writable (silent corruption path) */
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        p_free(&base);
        return 5;
    }
    p_free(&base);

    if (WIFSIGNALED(st) &&
        (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV))
        return 0;
    if (WIFEXITED(st))
        return 2;
    return 3;
}

/* Contract probe (panel H1/H2/H3 regressions, run against the dylib ABI):
 * returns the number of FAILED checks; 0 = all conform. */
int s1_contract_probe_run(void)
{
    int bad = 0;
    void *b, *g;
    size_t t;
    int rc;

    /* H2: guard_bytes == 0 must be -EINVAL (no silent one-page coercion). */
    if (p_alloc(256 * 1024, 16 * 1024, 0, &b, &g, &t) != -EINVAL)
        bad++;

    /* H2: non-page-multiple guard must be -EINVAL (no silent round-up). */
    if (p_alloc(256 * 1024, 16 * 1024, 1000, &b, &g, &t) != -EINVAL)
        bad++;

    /* Frozen contract: out-slots untouched on failure. */
    b = (void *)1;
    g = (void *)1;
    t = 1;
    rc = p_alloc(256 * 1024, 16 * 1024, 0, &b, &g, &t);
    if (rc != -EINVAL || b != (void *)1 || g != (void *)1 || t != 1)
        bad++;

    /* H3: rounding wrap-around via reserve must fail, not "succeed"
     * with a tiny guard-less mapping. */
    rc = p_alloc(SIZE_MAX, 0, 16384, &b, &g, &t);
    if (rc != -EINVAL && rc != -ENOMEM)
        bad++;

    /* H3: rounding wrap-around via initial_commit. */
    rc = p_alloc(256 * 1024, SIZE_MAX, 16384, &b, &g, &t);
    if (rc != -EINVAL && rc != -ENOMEM)
        bad++;

    /* H3: rounding wrap-around via guard_bytes near SIZE_MAX. */
    rc = p_alloc(16384, 0, SIZE_MAX - 4095, &b, &g, &t);
    if (rc != -EINVAL && rc != -ENOMEM)
        bad++;

    /* H2: NULL slot pointer and double-free are -EINVAL errors. */
    if (p_free(NULL) != -EINVAL)
        bad++;
    b = NULL;
    if (p_free(&b) != -EINVAL)
        bad++;

    /* Success path unchanged: alloc -> free -> double-free(-EINVAL). */
    rc = p_alloc(256 * 1024, 16 * 1024, 16384, &b, &g, &t);
    if (rc != 0 || b == NULL) {
        bad++;
    } else {
        if (p_free(&b) != 0 || b != NULL)
            bad++;
        if (p_free(&b) != -EINVAL)
            bad++;
    }
    return bad;
}