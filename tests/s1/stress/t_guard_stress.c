/*
 * t_guard_stress.c — S1 stress-lane guard probes (issue #31).
 *
 * Companion C helper for tests/s1/stress. Compiled once into .build/ by
 * tests/s1/stress/run.sh and linked INTO every stress-driver executable
 * (-Xlinker). It contains NO mojito-sys implementation symbols of its own:
 * it only provides deliberate-fault forks that a Mojo driver cannot express
 * safely (a synchronous fault in the driver process would kill the runner).
 *
 * Probe 1 — guard page (spec 6.5 / S0-T13 carried forward to S1):
 *   1. the parent forks a child;
 *   2. the child writes one byte into the middle of the guard-page region,
 *      which is the FIRST guard_bytes of the stack reservation (expected
 *      PROT_NONE);
 *   3. the parent reaps and REQUIRES the child to have died from a
 *      synchronous platform fault — SIGBUS on macOS arm64, SIGSEGV accepted;
 *   4. the child reaching _exit(0) means the guard page was writable or
 *      absent => silent-corruption path, a hard FAIL.
 *
 * Probe 2 — decommit negative control (review SHOULD-FIX 3):
 *   Same fork pattern against an arbitrary address the driver has just
 *   decommitted via its OWN conforming mjs_vm_decommit (mprotect PROT_NONE).
 *   Pins the relocation-blind-spot oracle: MADV_FREE laziness can keep old
 *   bytes readable after backing is dropped, so sentinel re-reads alone
 *   could pass a content-preserving relocation. A conforming decommit must
 *   flip the page loud — reading it in the child MUST fault; the child
 *   surviving means the oracle is blind and the driver hard-FAILs.
 *
 * Signal hygiene: async-signal-free child body, SIG_DFL reset before the
 * deliberate fault, _exit() (no atexit flush), waitpid retried on EINTR.
 *
 * Exports:
 *   int stress_guard_verdict(void *base, size_t guard_bytes)
 *   int stress_decommit_verdict(void *addr)
 *
 * Verdict codes (both probes):
 *   0  controlled fault (child WIFSIGNALED by SIGBUS/SIGSEGV)
 *   1  child exited normally => target writable/readable (silent path)
 *   2  child died from an unexpected signal
 *   3  fork failed
 *   4  waitpid failed
 */

#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

static int reap_fault(pid_t pid)
{
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR)
            return 4;
    }

    if (WIFSIGNALED(st) &&
        (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV))
        return 0;                       /* controlled fault */
    if (WIFEXITED(st))
        return 1;                       /* survived => target accessible */
    return 2;                           /* some other signal */
}

static pid_t fault_child(void)
{
    pid_t pid = fork();
    if (pid == 0) {
        /* Detach any runtime-installed fault handler so the deliberate
         * fault takes the platform default action cleanly. */
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
    }
    return pid;
}

int stress_guard_verdict(void *base, size_t guard_bytes)
{
    if (base == NULL || guard_bytes == 0)
        return 1;                       /* nothing to fault: guard absent */

    pid_t pid = fault_child();
    if (pid < 0)
        return 3;

    if (pid == 0) {
        /* Child: write into the middle of the guard page. This MUST raise
         * a synchronous protection fault; reaching _exit means the guard
         * was writable/absent (silent corruption path). */
        volatile char *guard = (volatile char *)base + guard_bytes / 2;
        *guard = 7;
        _exit(0);
    }
    return reap_fault(pid);
}

int stress_decommit_verdict(void *addr)
{
    if (addr == NULL)
        return 1;

    pid_t pid = fault_child();
    if (pid < 0)
        return 3;

    if (pid == 0) {
        /* Child: read the freshly decommitted address. A conforming
         * decommit left it PROT_NONE, so this MUST fault; surviving means
         * stale bytes are still readable (oracle blind). */
        volatile char *p = (volatile char *)addr;
        char v = *p;
        _exit(v == (char)0xAA ? 2 : 0);
    }
    return reap_fault(pid);
}
