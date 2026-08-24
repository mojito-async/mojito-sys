/*
 * t_guard_stress.c — S1 stress-lane guard probe (issue #31).
 *
 * Companion C helper for tests/s1/stress. Compiled once into .build/ by
 * tests/s1/stress/run.sh and linked INTO every stress-driver executable
 * (-Xlinker). It contains NO mojito-sys implementation symbols of its own:
 * it only provides the deliberate-fault fork that a Mojo driver cannot
 * express safely (a synchronous fault in the driver process would kill the
 * runner).
 *
 * Semantics verified (spec 6.5 / S0-T13 carried forward to S1):
 *   1. the parent forks a child;
 *   2. the child writes one byte into the middle of the guard-page region,
 *      which is the FIRST guard_bytes of the stack reservation (expected
 *      PROT_NONE);
 *   3. the parent reaps and REQUIRES the child to have Died from a
 *      synchronous platform fault — SIGBUS on macOS arm64, SIGSEGV accepted;
 *   4. the child reaching _exit(0) means the guard page was writable or
 *      absent => silent-corruption path, a hard FAIL.
 *
 * Exported:
 *   int  stress_guard_verdict(void *base, size_t guard_bytes)
 *
 * Verdict codes:
 *   0  controlled fault (child WIFSIGNALED by SIGBUS/SIGSEGV)
 *   1  child exited normally => guard writable/absent (silent corruption)
 *   2  child died from an unexpected signal
 *   3  fork failed
 *   4  waitpid failed
 */

#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

int stress_guard_verdict(void *base, size_t guard_bytes)
{
    if (base == NULL || guard_bytes == 0)
        return 1;                       /* nothing to fault: guard absent */

    pid_t pid = fork();
    if (pid < 0)
        return 3;

    if (pid == 0) {
        /* Detach any runtime-installed fault handler so the deliberate
         * fault takes the platform default action cleanly. */
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        /* Child: write into the middle of the guard page. This MUST raise a
         * synchronous protection fault; reaching _exit means the guard was
         * writable/absent (silent corruption path). */
        volatile char *guard = (volatile char *)base + guard_bytes / 2;
        *guard = 7;
        _exit(0);
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        return 4;

    if (WIFSIGNALED(st) &&
        (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV))
        return 0;                       /* controlled fault */
    if (WIFEXITED(st))
        return 1;                       /* survived => guard absent */
    return 2;                           /* some other signal */
}