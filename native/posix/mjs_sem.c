/* mojito-sys S3.7 — native counting semaphore layer (issue #106,
 * spec §14/§17).
 *
 * Composes the portable s3.1 + s3.2 primitives instead of touching
 * pthreads directly — one internal mjs_mutex + one internal
 * mjs_condvar (which owns ALL of the platform clock-domain handling:
 * Linux condattr CLOCK_MONOTONIC vs the macOS relative-NP fallback) +
 * one int permit count. The struct needs no shared layout header: it
 * holds only the opaque public handles.
 *
 * PERMIT-ACCOUNTING SEMANTICS (normative, mirrored in the header block
 * and pinned by tests/s3/sync/semaphore): a COUNTING semaphore keeps a
 * NON-NEGATIVE permit count.
 *   - post() increments the count and wakes AT MOST ONE parked waiter.
 *     With nobody waiting a post leaves the permit resident for a later
 *     wait — and permits ACCUMULATE: N posts with no waiter leave N
 *     permits, so exactly N later waits complete without blocking (a
 *     counting semaphore, NOT NativeEvent's coalescing signal).
 *   - wait()/wait_until() block while the count is zero, then
 *     DECREMENT it — each permit is consumed by exactly ONE wait.
 *   - try_wait() acquires without blocking: 0 if a permit was taken,
 *     -EBUSY (a STATUS, like try_lock's) when the semaphore is empty.
 *   - The count is conserved across posts and waits and can never
 *     underflow below zero: an acquisition that would take the count
 *     negative instead blocks (or returns -EBUSY via try_wait).
 *   - Fairness is NOT promised: a fresh arrival may acquire a permit
 *     ahead of an already-woken waiter that has not yet reacquired the
 *     internal mutex.
 *
 * IMPLEMENTATION COMPOSITION: mirrors mjs_event.c — this layer composes
 * the portable s3-mutex + s3-condvar primitives (one internal mutex,
 * one internal condvar pinned per the s3-condvar clock domain, one int
 * count). The atomic-wait layer has landed on main (#59/#60); an
 * uncontended fast path COULD slot into wait/wait_until/try_wait/post
 * with an atomic count read and mjs_atomic_wait_u32, but the mutex+
 * condvar composition is correct and simple for this leg.
 *
 * LOST-WAKEUP FREEDOM: every state transition happens under the
 * internal mutex — a post racing a waiter between its predicate check
 * and its sleep increments the count the waiter then observes on entry.
 * The predicate loop below therefore cannot miss a wake, and expiry
 * parity (wake beats timeout) is preserved exactly like the event and
 * atomic-wait layers: a wait_until that observes the deadline expired
 * only reports -ETIMEDOUT if it ALSO re-checked the count and found no
 * permit — a permit visible at the re-check is consumed and 0 returned.
 *
 * Linux-portable: no platform ifdefs are needed here at all — the
 * clock split lives entirely inside mjs_condvar.c. The one Darwin-
 * free assumption is that mjs_mutex_init/mjs_condvar_init succeed
 * before *out is written; on failure the handle is freed and *out
 * stays untouched (out-params untouched on failure).
 */

#include "mojito_sys.h"

#include <errno.h>
#include <stdlib.h>

struct mjs_sem {
    mjs_mutex *m;    /* guards `count` */
    mjs_condvar *cv; /* permit-queue */
    int count;       /* current permits; NEVER negative */
};

int mjs_sem_init(int initial, mjs_sem **out) {
    if (out == NULL)
        return -EFAULT;
    if (initial < 0)
        return -EINVAL; /* a permit count can never be negative */
    mjs_sem *s = malloc(sizeof(*s));
    if (s == NULL)
        return -ENOMEM;
    s->count = initial;
    int rc = mjs_mutex_init(&s->m);
    if (rc != 0) {
        free(s);
        return rc;
    }
    rc = mjs_condvar_init(&s->cv);
    if (rc != 0) {
        mjs_mutex_destroy(&s->m); /* unwinds cleanly: handle still live */
        free(s);
        return rc;
    }
    *out = s;
    return 0;
}

int mjs_sem_post(mjs_sem *s) {
    if (s == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(s->m);
    if (rc != 0)
        return rc;
    s->count++; /* permits accumulate (counting semaphore, no coalescing) */
    rc = mjs_condvar_signal(s->cv); /* wake at most one waiter */
    int urc = mjs_mutex_unlock(s->m);
    return rc != 0 ? rc : urc;
}

int mjs_sem_wait(mjs_sem *s) {
    if (s == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(s->m);
    if (rc != 0)
        return rc;
    while (s->count == 0) {
        rc = mjs_condvar_wait(s->cv, s->m);
        if (rc != 0) {
            mjs_mutex_unlock(s->m);
            return rc;
        }
        /* Spurious wakes are permitted by contract; only a positive
         * count ends the loop. */
    }
    s->count--; /* consume exactly one permit */
    return mjs_mutex_unlock(s->m);
}

/* EXPIRY PARITY: a wait_until whose deadline expired still consumes a
 * permit that became visible before the re-check (wake beats timeout) —
 * it returns 0, never -ETIMEDOUT with a permit left pending. */
int mjs_sem_wait_until(mjs_sem *s, uint64_t deadline_ns) {
    if (s == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(s->m);
    if (rc != 0)
        return rc;
    while (s->count == 0) {
        rc = mjs_condvar_wait_until(s->cv, s->m, deadline_ns);
        if (rc != 0 && s->count == 0) {
            /* -ETIMEDOUT (status) or a real error, with NO permit
             * visible at the re-check: propagate with the mutex
             * released. */
            mjs_mutex_unlock(s->m);
            return rc;
        }
        /* Otherwise fall through and consume the (now visible) permit. */
    }
    s->count--; /* consume exactly one permit */
    return mjs_mutex_unlock(s->m);
}

/* Non-blocking acquire. 0 when a permit was taken; -EBUSY (a STATUS, not
 * a failure) when the semaphore is empty; another negative on error. */
int mjs_sem_try_wait(mjs_sem *s) {
    if (s == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(s->m);
    if (rc != 0)
        return rc;
    if (s->count == 0) {
        mjs_mutex_unlock(s->m);
        return -EBUSY; /* STATUS: no permit available, did not block */
    }
    s->count--;
    return mjs_mutex_unlock(s->m);
}

int mjs_sem_destroy(mjs_sem **s) {
    if (s == NULL || *s == NULL)
        return -EINVAL;
    /* Precondition (caller-enforced): no thread may still be waiting. */
    int rc = mjs_condvar_destroy(&(*s)->cv);
    if (rc != 0)
        return rc; /* handle NOT consumed on failure */
    rc = mjs_mutex_destroy(&(*s)->m);
    if (rc != 0)
        return rc; /* cv already gone; keep the same no-consume rule */
    free(*s);
    *s = NULL;
    return 0;
}