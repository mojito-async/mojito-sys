/* mojito-sys S3.2 — native condition variable layer (issue #58, spec §16).
 *
 * pthread-backed implementation of the mjs_condvar_* surface declared in
 * native/include/mojito_sys.h under the s3-condvar block and the frozen
 * contract:
 *   0 == success; negative == -errno; out-params untouched on failure.
 *   wait_until: 0 = woken (predicate may still be false — spurious
 *   wakes are permitted by contract), -ETIMEDOUT = deadline expired
 *   (a STATUS, like try_lock's -EBUSY), any other negative = error.
 *
 * Handle lifetime model (see header block):
 *   - init mallocs a fixed-size handle wrapping a pthread_cond_t and
 *     hands the only reference to the caller;
 *   - destroy runs pthread_cond_destroy, frees the handle and NULLs *c,
 *     so any later use (double destroy included) is a deterministic
 *     -EINVAL before anything else happens.
 *
 * CLOCK-DOMAIN CONVERSION (the issue #58 trap):
 *   mjs_clock_now normalizes monotonic time to plain nanoseconds. For
 *   wait_until that deadline must reach pthread_cond_timedwait as a
 *   timespec on whatever clock THAT condvar was initialized with:
 *
 *   - Linux (and any POSIX with pthread_condattr_setclock): the condvar
 *     is created with condattr clock CLOCK_MONOTONIC, so deadline_ns IS
 *     a CLOCK_MONOTONIC abstime — {tv_sec = ns/1e9, tv_nsec = ns%1e9},
 *     no arithmetic beyond the split.
 *
 *   - macOS has NO pthread_condattr_setclock (the default cond waits on
 *     an internal clock derived from gettimeofday; CLOCK_REALTIME is not
 *     selectable either). The documented equivalent is
 *     pthread_cond_timedwait_relative_np: we pass the RELATIVE remainder
 *     deadline_ns - <monotonic now>, where "now" comes from
 *     mjs_clock_now() itself — the SAME exported source the Mojo side
 *     computes deadlines from, so both halves of the conversion share
 *     one time domain and no mach timebase math is duplicated here.
 *     The remainder is recomputed at every call entry; POSIX spurious
 *     wakes return to the caller, whose predicate loop re-enters
 *     wait_until and re-derives a fresh remainder. A non-positive
 *     remainder short-circuits to -ETIMEDOUT without entering the wait.
 *
 * Linux-portable: no Mach/_np symbols are referenced unless the
 * __APPLE__ path is compiled; no -arch or platform flags needed.
 */
#include "mojito_sys.h"

/* PRIVATE shared layout of struct mjs_mutex (&m->pm feeds
 * pthread_cond_*); public ABI stays opaque in ../include/mojito_sys.h. */
#include "mjs_sync_internal.h"

#include <errno.h>
#include <stdlib.h>
#include <time.h>

#include <pthread.h>

struct mjs_condvar {
    pthread_cond_t pc;
};

int mjs_condvar_init(mjs_condvar **out) {
    if (out == NULL)
        return -EFAULT;
    mjs_condvar *c = malloc(sizeof(*c));
    if (c == NULL)
        return -ENOMEM;
#if defined(__APPLE__)
    /* macOS: default attributes; timed waits go through the relative-NP
     * fallback (see file comment). */
    int rc = pthread_cond_init(&c->pc, NULL);
#else
    /* Linux: pin the cond's internal clock to CLOCK_MONOTONIC so an
     * absolute deadline in mjs_clock_now() nanoseconds maps 1:1 onto
     * pthread_cond_timedwait's abstime. */
    pthread_condattr_t ca;
    int rc = pthread_condattr_init(&ca);
    if (rc != 0) {
        free(c);
        return -rc;
    }
    rc = pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    if (rc != 0) {
        pthread_condattr_destroy(&ca);
        free(c);
        return -rc;
    }
    rc = pthread_cond_init(&c->pc, &ca);
    pthread_condattr_destroy(&ca);
#endif
    if (rc != 0) {
        free(c);
        return -rc;
    }
    *out = c;
    return 0;
}

int mjs_condvar_wait(mjs_condvar *c, mjs_mutex *m) {
    if (c == NULL || m == NULL)
        return -EINVAL;
    int rc = pthread_cond_wait(&c->pc, &m->pm);
    return rc == 0 ? 0 : -rc;
}

int mjs_condvar_wait_until(mjs_condvar *c, mjs_mutex *m,
                           uint64_t deadline_ns) {
    if (c == NULL || m == NULL)
        return -EINVAL;
    struct timespec ts;

#ifdef __APPLE__
    uint64_t now = 0;
    if (mjs_clock_now(&now) != 0)
        return -EINVAL; /* clock unavailable: cannot honor the deadline */
    if (deadline_ns <= now)
        return -ETIMEDOUT; /* past deadline: immediate status */
    uint64_t remaining = deadline_ns - now;
    ts.tv_sec = (time_t)(remaining / UINT64_C(1000000000));
    ts.tv_nsec = (long)(remaining % UINT64_C(1000000000));
    /* Relative fallback computed from the same monotonic source as the
     * deadline (file comment). Spurious wakes propagate to the caller's
     * predicate loop, which re-enters with a fresh remainder. */
    int rc = pthread_cond_timedwait_relative_np(&c->pc, &m->pm, &ts);
#else
    /* condattr pinned this cond to CLOCK_MONOTONIC at init, so the
     * absolute deadline converts directly. */
    ts.tv_sec = (time_t)(deadline_ns / UINT64_C(1000000000));
    ts.tv_nsec = (long)(deadline_ns % UINT64_C(1000000000));
    int rc = pthread_cond_timedwait(&c->pc, &m->pm, &ts);
#endif

    if (rc == ETIMEDOUT)
        return -ETIMEDOUT; /* STATUS, not a failure */
    return rc == 0 ? 0 : -rc;
}

int mjs_condvar_signal(mjs_condvar *c) {
    if (c == NULL)
        return -EINVAL;
    int rc = pthread_cond_signal(&c->pc);
    return rc == 0 ? 0 : -rc;
}

int mjs_condvar_broadcast(mjs_condvar *c) {
    if (c == NULL)
        return -EINVAL;
    int rc = pthread_cond_broadcast(&c->pc);
    return rc == 0 ? 0 : -rc;
}

int mjs_condvar_destroy(mjs_condvar **c) {
    if (c == NULL || *c == NULL)
        return -EINVAL;
    int rc = pthread_cond_destroy(&(*c)->pc);
    if (rc != 0)
        return -rc; /* handle NOT consumed on failure */
    free(*c);
    *c = NULL;
    return 0;
}
