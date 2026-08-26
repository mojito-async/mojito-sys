/* mojito-sys S3.3 — atomic wait/wake on u32 words (issue #59, spec §18).
 *
 * Implements the mjs_atomic_* surface declared in
 * native/include/mojito_sys.h under the s3-atomic-wait block.
 *
 * Backend coverage THIS ISSUE (per issue #59): Linux futex only, via the
 * FUTEX_WAIT_PRIVATE / FUTEX_WAKE_PRIVATE fast (non-realtime, per-process)
 * ops. Windows WaitOnAddress/WakeByAddress* and the macOS public-mechanism
 * fallback are later issues (#60 et al.); every other host takes the
 * documented -ENOSYS stub so callers and the backend-parameterized suite
 * (tests/s3/sync/atomic_wait/) red-exclude cleanly instead of hanging.
 *
 * TIME64 SAFETY: the kernel timeout is never an absolute deadline. The
 * wait loop re-derives the REMAINING span against mjs_clock_now
 * (CLOCK_MONOTONIC under the hood) before each futex attempt and passes
 * that as a relative timespec. Remaining spans of real schedulers are
 * small, so tv_sec fits a 32-bit time_t on every legacy kernel/arch — no
 * futex_time64 dependency anywhere in this file.
 *
 * EINTR / spurious handling: a signal-interrupted wait (futex -EINTR) or
 * any other wake without a predicate guarantee simply re-enters the loop:
 * the value is atomically re-checked by the next FUTEX_WAIT itself, which
 * also closes the lost-wake race between "deadline expired" and "word
 * changed" (an expired deadline still goes through the kernel's atomic
 * value check with a zero-length timeout).
 */
#include "mojito_sys.h"

#include <errno.h>

#if defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#endif

#if defined(__linux__)

/* One raw futex(2) syscall; ts == NULL means "no timeout". Private (same
 * process) op set only — spec §18 forbids private KERNEL interfaces, but
 * the _PRIVATE futex ops are stable public ABI since Linux 2.6.22. */
static long mjs_futex(uint32_t *uaddr, int op, uint32_t val,
                      const struct timespec *ts) {
    return syscall(SYS_futex, uaddr, op, val, ts, NULL, 0);
}

static int mjs_atomic_wait_linux(const uint32_t *addr, uint32_t expected,
                                 const uint64_t *deadline_ns) {
    for (;;) {
        struct timespec remaining;
        struct timespec *ts = NULL;
        if (deadline_ns != NULL) {
            uint64_t now = 0;
            if (mjs_clock_now(&now) != 0)
                return -EINVAL; /* clock failure: refuse to guess a span */
            uint64_t rem =
                (*deadline_ns <= now) ? 0 : (*deadline_ns - now);
            /* rem == 0 keeps the expiry race-safe: the kernel still
             * atomically checks the word first (EAGAIN -> ok) before
             * reporting ETIMEDOUT, so a change racing the deadline can
             * never be misreported as a timeout. */
            remaining.tv_sec = (time_t)(rem / 1000000000ULL);
            remaining.tv_nsec = (long)(rem % 1000000000ULL);
            ts = &remaining;
        }
        long rc = mjs_futex((uint32_t *)addr, FUTEX_WAIT_PRIVATE, expected, ts);
        if (rc == 0)
            return 0; /* woken by a wake_one/wake_all */
        int err = errno;
        if (err == EAGAIN)
            return 0; /* DOCUMENTED: word != expected at sleep time -> .ok */
        if (err == EINTR)
            continue; /* signal: re-check + re-arm the remaining span */
        if (err == ETIMEDOUT)
            return -ETIMEDOUT;
        return -err;
    }
}

#endif /* __linux__ */

int mjs_atomic_wait_on_u32(const uint32_t *addr, uint32_t expected,
                           const uint64_t *deadline_ns) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    return mjs_atomic_wait_linux(addr, expected, deadline_ns);
#else
    (void)expected; /* documented stub: no backend on this host yet */
    (void)deadline_ns;
    return -ENOSYS;
#endif
}

int mjs_atomic_wake_one_u32(uint32_t *addr) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    long rc = mjs_futex(addr, FUTEX_WAKE_PRIVATE, 1, NULL);
    return rc >= 0 ? (int)rc : -errno;
#else
    (void)addr;
    return -ENOSYS;
#endif
}

int mjs_atomic_wake_all_u32(uint32_t *addr) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    /* INT_MAX waiter cap: every current waiter, exactly the wake_all
     * semantic; no practical queue can hold more. */
    long rc = mjs_futex(addr, FUTEX_WAKE_PRIVATE, 0x7fffffff, NULL);
    return rc >= 0 ? (int)rc : -errno;
#else
    (void)addr;
    return -ENOSYS;
#endif
}
