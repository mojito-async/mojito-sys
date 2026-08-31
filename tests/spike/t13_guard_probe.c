/*
 * t13_guard_probe.c — S0/M1.4-T13 probe: guard-page overflow faults in a
 * controlled way (macOS arm64). RE-POINTED (#128): takes the address
 * geometry (base, guard_low, top) directly from a
 * spike/stack_switch/native_stack.mojo NativeStack the Mojo driver
 * already created, instead of calling the spike's own dlsym'd
 * ms_stack_alloc/ms_stack_free/ms_page_size. There is no context-switch
 * machinery involved in this test at all -- it is purely about the guard
 * page NativeStack.create() already painted PROT_NONE, so it needs no
 * ms_context_* binding and no dlopen/dlsym indirection either: NativeStack
 * owns alloc/free itself now, and the Mojo driver keeps it alive for the
 * duration of this call (see t13_guard_page.mojo's header for the
 * mojito-sys#204 keep-alive note).
 *
 * Semantics verified (unchanged from the S0 version):
 *   1. The highest usable byte of the guarded stack ([top - 1]) is
 *      writable in the parent (no false faults at the boundary).
 *   2. A forked child deliberately writing into the reserved PROT_NONE
 *      guard region [base, guard_low) dies from a synchronous hardware
 *      fault -- SIGBUS or SIGSEGV. Observed platform behavior: macOS
 *      arm64 delivers SIGBUS for accesses to an existing PROT_NONE page;
 *      either signal means overflow produced an immediate, contained
 *      platform fault rather than silent corruption of adjacent memory.
 *
 * Exported:
 *   int  t13_run(intptr_t base, intptr_t guard_low, intptr_t top);
 *        verdict code (0 = pass)
 *
 * Verdict codes from t13_run:
 *   0  controlled fault in child + healthy top-of-stack write in parent
 *   2  child exited normally (overflow did NOT fault => silent corruption)
 *   3  child died from some other unexpected signal
 *   5  waitpid failed
 */

#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

int t13_run(intptr_t base, intptr_t guard_low, intptr_t top)
{
    /*
     * Sanity in the parent: the single highest usable byte of the stack must
     * be writable. If this faults there is nothing to test.
     */
    volatile char *ok_byte = (volatile char *)top - 1;
    *ok_byte = 42;

    pid_t pid = fork();
    if (pid < 0)
        return 5;
    if (pid == 0) {
        /* Detach from any runtime-installed fault handlers so the
         * deliberate fault takes the platform default action cleanly. */
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        /* Child: write into the middle of the guard region [base, guard_low).
         * This MUST raise a synchronous protection fault (SIGBUS on macOS
         * arm64, SIGSEGV elsewhere); reaching _exit means the guard page was
         * absent or writable (silent corruption path). */
        volatile char *guard = (volatile char *)base + (guard_low - base) / 2;
        *guard = 7;
        _exit(0);
    }

    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        return 5;

    int controlled = WIFSIGNALED(st) &&
                     (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV);
    if (controlled)
        return 0;
    if (WIFEXITED(st))
        return 2;
    return 3;
}
