/*
 * t13_guard_probe.c — S0-T13 probe: guard-page overflow faults in a
 * controlled way (macOS arm64).
 *
 * Owner: tests lane B (issue #12). Compiled to a relocatable object and
 * linked INTO the t13_guard_page executable. No link-time spike references:
 * symbols are dlsym'd at runtime after the Mojo driver dlopen()s
 * libmojito_spike.dylib, so a missing implementation yields a deterministic
 * RED verdict instead of a load failure.
 *
 * Semantics verified:
 *   1. The highest usable byte of a freshly allocated guarded stack is
 *      writable in the parent (no false faults at the boundary).
 *   2. A forked child deliberately writing into the reserved PROT_NONE guard
 *      page dies from a synchronous hardware fault — SIGBUS or SIGSEGV.
 *      Observed platform behavior: macOS arm64 delivers SIGBUS for accesses
 *      to an existing PROT_NONE page; either signal means overflow produced
 *      an immediate, contained platform fault rather than silent corruption
 *      of adjacent memory.
 *
 * Exported:
 *   int  t13_init(void);            0 = every required symbol resolved
 *   int  t13_run(size_t bytes);     verdict code (0 = pass)
 *
 * Verdict codes from t13_run:
 *   0  controlled fault in child + healthy top-of-stack write in parent
 *   2  child exited normally (overflow did NOT fault => silent corruption)
 *   3  child died from some other unexpected signal
 *   4  ms_stack_alloc failed
 *   5  waitpid failed
 */

#include <dlfcn.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef int (*ms_stack_alloc_fn)(size_t bytes, void **out_base, void **out_top);
typedef void (*ms_stack_free_fn)(void *base);
typedef int (*ms_page_size_fn)(void);

static ms_stack_alloc_fn  p_alloc;
static ms_stack_free_fn   p_free;
static ms_page_size_fn    p_pagesize;

int t13_init(void)
{
    void *h = dlopen("libmojito_spike.dylib", RTLD_NOW | RTLD_GLOBAL);
    if (h == NULL)
        return 1;
    p_alloc    = (ms_stack_alloc_fn)dlsym(RTLD_DEFAULT, "ms_stack_alloc");
    p_free     = (ms_stack_free_fn)dlsym(RTLD_DEFAULT, "ms_stack_free");
    p_pagesize = (ms_page_size_fn)dlsym(RTLD_DEFAULT, "ms_page_size");
    if (p_alloc == NULL || p_free == NULL || p_pagesize == NULL)
        return 1;
    return 0;
}

int t13_run(size_t bytes)
{
    if (p_alloc == NULL || p_free == NULL || p_pagesize == NULL)
        return 4;

    void *base = NULL;
    void *top = NULL;
    if (p_alloc(bytes, &base, &top) != 0 || base == NULL || top == NULL)
        return 4;

    /*
     * Sanity in the parent: the single highest usable byte of the stack must
     * be writable. If this faults there is nothing to test.
     */
    volatile char *ok_byte = (volatile char *)top - 1;
    *ok_byte = 42;

    pid_t pid = fork();
    if (pid < 0) {
        p_free(base);
        return 5;
    }
    if (pid == 0) {
        /* Child: write into the middle of the guard page [base, base+ps).
         * This MUST raise a synchronous protection fault (SIGBUS on macOS
         * arm64, SIGSEGV elsewhere); reaching _exit means the guard page was
         * absent or writable (silent corruption path). */
        volatile char *guard = (volatile char *)base + p_pagesize() / 2;
        *guard = 7;
        _exit(0);
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        p_free(base);
        return 5;
    }
    p_free(base);

    int controlled = WIFSIGNALED(st) &&
                     (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV);
    if (controlled)
        return 0;
    if (WIFEXITED(st))
        return 2;
    return 3;
}
