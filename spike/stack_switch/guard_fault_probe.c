/*
 * guard_fault_probe.c -- M1.4 (#128) TEST-ONLY oracle: verify a guard page
 * at [base, base+page_size) faults a forked child that writes into it.
 * Same convention as tests/spike/t13_guard_probe.c (a small C helper linked
 * directly into the test binary; not a production shim, spec #14 governs
 * production code only).
 *
 * Used identically against BOTH NativeStack's own mmap'd guard (Mojo, this
 * leg) and native/posix/mjs_stack.c's mjs_stack_alloc guard (the C oracle),
 * so the SAME verdict function proves the two implementations fault the
 * same way for the same layout -- the "matches the C implementation"
 * half of #128's acceptance bar.
 *
 * Verdict codes:
 *   0  controlled fault in the child (SIGBUS or SIGSEGV) -- guard works
 *   2  child exited normally -- guard page absent/writable (BUG: silent
 *      corruption path)
 *   3  child died from some other, unexpected signal
 *   5  fork()/waitpid() itself failed (environment problem)
 */
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

int msw_guard_fault_check(void *guard_addr) {
    pid_t pid = fork();
    if (pid < 0)
        return 5;

    if (pid == 0) {
        /* Detach from any runtime-installed fault handlers so the
         * deliberate fault takes the platform default action cleanly. */
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        volatile char *guard = (volatile char *)guard_addr;
        *guard = 7;
        _exit(0);
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        return 5;

    if (WIFSIGNALED(st) && (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV))
        return 0;
    if (WIFEXITED(st))
        return 2;
    return 3;
}
