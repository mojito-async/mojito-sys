/* mojito-sys S3.1 — native C smoke for the mjs_mutex_* surface (issue #57).
 *
 * Pins the frozen s3-mutex ABI contract directly against
 * libmojito_sys.dylib (the link makes a missing export a hard failure,
 * so this suite stays red until native/posix/mjs_mutex.c lands):
 *
 *   1. init/lock/try_lock/unlock roundtrip + consume-on-destroy;
 *   2. NULL/out-slot contract: init(NULL) == -EFAULT, any primitive on a
 *      NULL handle == -EINVAL, out-params untouched on failure;
 *   3. cross-thread try_lock handshake (raw pthreads): the child sees
 *      -EBUSY while the parent holds the lock and acquires it (0) after
 *      the parent releases; ordering through C11 atomics;
 *   4. contention: 8 pthreads x 10k guarded increments == 80000 EXACTLY.
 *
 * Usage: linked by tests/s3/sync/mutex/run.sh against the packaged dylib.
 */
#include "mojito_sys.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

static int failures = 0;

#define CHECK(cond, name)                                                  \
    do {                                                                   \
        if (cond) {                                                        \
            printf("%s: PASS\n", name);                                    \
        } else {                                                           \
            printf("%s: FAIL\n", name);                                    \
            failures++;                                                    \
        }                                                                  \
    } while (0)

/* ---- 3. cross-thread try_lock handshake ------------------------------------ */

typedef struct {
    mjs_mutex *m;
    atomic_int phase; /* 1: child saw -EBUSY; 2: parent released; 3: done */
    int saw_busy;     /* nonzero when first try_lock returned -EBUSY */
    int got_free;     /* nonzero when second try_lock returned 0 */
} handshake_t;

static void *handshake_child(void *arg) {
    handshake_t *hs = arg;
    /* Parent locked hs->m BEFORE pthread_create, so the first try must
     * observe -EBUSY. */
    hs->saw_busy = (mjs_mutex_try_lock(hs->m) == -EBUSY);
    atomic_store(&hs->phase, 1);
    while (atomic_load(&hs->phase) != 2)
        usleep(100); /* wait for the parent to release */
    hs->got_free = (mjs_mutex_try_lock(hs->m) == 0);
    if (hs->got_free)
        mjs_mutex_unlock(hs->m);
    atomic_store(&hs->phase, 3);
    return NULL;
}

/* ---- 4. contention stress --------------------------------------------------- */

#define STRESS_THREADS 8
#define STRESS_ITERS 10000

typedef struct {
    mjs_mutex *m;
    long *counter;
} stress_arg_t;

static void *stress_child(void *arg) {
    stress_arg_t *sa = arg;
    for (int i = 0; i < STRESS_ITERS; i++) {
        mjs_mutex_lock(sa->m);
        (*sa->counter)++;
        mjs_mutex_unlock(sa->m);
    }
    return NULL;
}

int main(void) {
    /* ---- 1. roundtrip + consume ------------------------------------------------ */
    mjs_mutex *m = NULL;
    CHECK(mjs_mutex_init(&m) == 0 && m != NULL, "C init adopts handle");
    CHECK(mjs_mutex_lock(m) == 0, "C lock");
    CHECK(mjs_mutex_try_lock(m) == -EBUSY, "C try_lock held == -EBUSY");
    CHECK(mjs_mutex_unlock(m) == 0, "C unlock");
    CHECK(mjs_mutex_try_lock(m) == 0, "C try_lock free == 0");
    CHECK(mjs_mutex_unlock(m) == 0, "C unlock (from try_lock)");
    mjs_mutex *consumed = m;
    CHECK(mjs_mutex_destroy(&m) == 0 && m == NULL, "C destroy consumes (*m NULLed)");
    CHECK(mjs_mutex_destroy(&consumed) == -EINVAL, "C double destroy == -EINVAL");

    /* ---- 2. NULL / untouched-out contract -------------------------------------- */
    mjs_mutex *keep = (mjs_mutex *)0x1;
    CHECK(mjs_mutex_init(NULL) == -EFAULT, "C init(NULL) == -EFAULT");
    CHECK(mjs_mutex_lock(NULL) == -EINVAL, "C lock(NULL) == -EINVAL");
    CHECK(mjs_mutex_try_lock(NULL) == -EINVAL, "C try_lock(NULL) == -EINVAL");
    CHECK(mjs_mutex_unlock(NULL) == -EINVAL, "C unlock(NULL) == -EINVAL");
    CHECK(mjs_mutex_destroy(NULL) == -EINVAL, "C destroy(NULL) == -EINVAL");
    CHECK(keep == (mjs_mutex *)0x1, "C out-param untouched on failure");

    /* ---- 3. cross-thread try_lock handshake ------------------------------------- */
    handshake_t hs;
    memset(&hs, 0, sizeof hs);
    CHECK(mjs_mutex_init(&hs.m) == 0, "C handshake mutex init");
    CHECK(mjs_mutex_lock(hs.m) == 0, "C handshake parent lock");
    pthread_t child;
    int crc = pthread_create(&child, NULL, handshake_child, &hs);
    if (crc == 0) {
        while (atomic_load(&hs.phase) != 1)
            usleep(100);
        CHECK(mjs_mutex_unlock(hs.m) == 0, "C handshake parent unlock");
        atomic_store(&hs.phase, 2);
        pthread_join(child, NULL);
        CHECK(hs.saw_busy && hs.got_free, "C handshake child busy-then-free");
    } else {
        printf("C handshake child spawn: FAIL\n");
        failures++;
    }
    CHECK(mjs_mutex_destroy(&hs.m) == 0 && hs.m == NULL,
          "C handshake destroy clean");

    /* ---- 4. contention stress ----------------------------------------------------- */
    mjs_mutex *sm = NULL;
    long counter = 0;
    CHECK(mjs_mutex_init(&sm) == 0, "C stress mutex init");
    pthread_t workers[STRESS_THREADS];
    stress_arg_t sa = {sm, &counter};
    int spawned = 1;
    for (int i = 0; i < STRESS_THREADS; i++) {
        if (pthread_create(&workers[i], NULL, stress_child, &sa) != 0)
            spawned = 0;
    }
    if (spawned) {
        for (int i = 0; i < STRESS_THREADS; i++)
            pthread_join(workers[i], NULL);
    }
    CHECK(spawned && counter == (long)STRESS_THREADS * STRESS_ITERS,
          "C contention 8x10k == 80000 exactly");
    CHECK(mjs_mutex_destroy(&sm) == 0, "C stress destroy clean");

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d FAILED\n", failures);
    return 1;
}
