/* mojito-sys S3.5 — native event layer (issue #61, spec §17).
 *
 * pthread-backed implementation of the mjs_event_* surface declared in
 * native/include/mojito_sys.h under the s3-event block and the frozen
 * contract:
 *   0 == success; negative == -errno; out-params untouched on failure.
 *   wait_until: 0 = token consumed, -ETIMEDOUT = deadline expired (a
 *   STATUS, like try_lock's -EBUSY), any other negative = error.
 *
 * WAKE SEMANTICS (normative, mirrored in the header block): AUTO-RESET,
 * BREADTH-ONE. At most one token is pending at any time. signal stores
 * a token and wakes at most one parked waiter; with nobody waiting the
 * token sticks so exactly ONE later wait completes without blocking.
 * Signals issued while a token is already pending coalesce. A
 * successful wait consumes the token; every other waiter keeps
 * sleeping until the next signal. Fairness is not promised (a fresh
 * arrival may consume the token ahead of an already-woken waiter that
 * has not yet reacquired the internal mutex).
 *
 * IMPLEMENTATION COMPOSITION: this file composes the portable s3.1 +
 * s3.2 primitives instead of touching pthreads directly — one internal
 * mjs_mutex + one internal mjs_condvar (which owns ALL of the platform
 * clock-domain handling: Linux condattr CLOCK_MONOTONIC vs the macOS
 * relative-NP fallback) + one int token. The struct needs no shared
 * layout header: it holds only the opaque public handles.
 *
 * FUTURE FAST PATH (documented where it slots in, per issue #61):
 * when the atomic-wait layer lands on main (s3/atomic-wait, PR #99
 * branch), wait/wait_until gain an uncontended atomic acquire-load
 * short-circuit on the token and their slow path becomes
 * mjs_atomic_wait_u32(&e->token, 0, ...); signal becomes a store-
 * release plus mjs_atomic_wake_u32_one(&e->token). The frozen ABI in
 * ../include/mojito_sys.h does NOT change.
 *
 * LOST-WAKEUP FREEDOM: every state transition happens under the
 * internal mutex — a signal racing a waiter between its predicate
 * check and its sleep can only store the token the waiter then finds
 * on entry. The predicate loop below therefore cannot miss a wake.
 *
 * Linux-portable: no platform ifdefs are needed here at all — the
 * clock split lives entirely inside mjs_condvar.c.
 */

#include "mojito_sys.h"

#include <errno.h>
#include <stdlib.h>

struct mjs_event {
    mjs_mutex *m;    /* guards `signaled` */
    mjs_condvar *cv; /* parked-waiter queue */
    int signaled;    /* 0 = no token, 1 = one pending token */
};

int mjs_event_init(mjs_event **out) {
    if (out == NULL)
        return -EFAULT;
    mjs_event *e = malloc(sizeof(*e));
    if (e == NULL)
        return -ENOMEM;
    e->signaled = 0;
    int rc = mjs_mutex_init(&e->m);
    if (rc != 0) {
        free(e);
        return rc;
    }
    rc = mjs_condvar_init(&e->cv);
    if (rc != 0) {
        mjs_mutex_destroy(&e->m); /* unwinds cleanly: handle still live */
        free(e);
        return rc;
    }
    *out = e;
    return 0;
}

int mjs_event_wait(mjs_event *e) {
    if (e == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(e->m);
    if (rc != 0)
        return rc;
    while (e->signaled == 0) {
        rc = mjs_condvar_wait(e->cv, e->m);
        if (rc != 0) {
            mjs_mutex_unlock(e->m);
            return rc;
        }
        /* Spurious wakes are permitted by contract; only a visible
         * token ends the loop. */
    }
    e->signaled = 0; /* CONSUME the single token */
    return mjs_mutex_unlock(e->m);
}

int mjs_event_wait_until(mjs_event *e, uint64_t deadline_ns) {
    if (e == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(e->m);
    if (rc != 0)
        return rc;
    while (e->signaled == 0) {
        rc = mjs_condvar_wait_until(e->cv, e->m, deadline_ns);
        if (rc != 0) {
            /* -ETIMEDOUT (status) or a real error: no token either
             * way, propagate with the mutex released. */
            mjs_mutex_unlock(e->m);
            return rc;
        }
    }
    e->signaled = 0; /* CONSUME the single token */
    return mjs_mutex_unlock(e->m);
}

int mjs_event_signal(mjs_event *e) {
    if (e == NULL)
        return -EINVAL;
    int rc = mjs_mutex_lock(e->m);
    if (rc != 0)
        return rc;
    if (e->signaled == 0) {
        e->signaled = 1; /* store the ONE token */
        rc = mjs_condvar_signal(e->cv);
    }
    /* else: coalesce — a pending token already covers this signal. */
    int urc = mjs_mutex_unlock(e->m);
    return rc != 0 ? rc : urc;
}

int mjs_event_destroy(mjs_event **e) {
    if (e == NULL || *e == NULL)
        return -EINVAL;
    /* Precondition (caller-enforced): no thread may still be waiting. */
    int rc = mjs_condvar_destroy(&(*e)->cv);
    if (rc != 0)
        return rc; /* handle NOT consumed on failure */
    rc = mjs_mutex_destroy(&(*e)->m);
    if (rc != 0)
        return rc; /* cv already gone; keep the same no-consume rule */
    free(*e);
    *e = NULL;
    return 0;
}
