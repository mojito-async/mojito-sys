/* mojito-sys S3.2 — native C smoke for the mjs_condvar_* surface (issue #58).
 *
 * Pins the frozen s3-condvar ABI contract directly against
 * libmojito_sys.dylib (the link makes a missing export a hard failure,
 * so this suite stays red until native/posix/mjs_condvar.c lands):
 *
 *   1. init/signal/broadcast roundtrip + consume-on-destroy;
 *   2. NULL/out-slot contract: init(NULL) == -EFAULT, any primitive on a
 *      NULL handle == -EINVAL;
 *   3. past-deadline wait_until == -ETIMEDOUT immediately (measured);
 *   4. future-deadline wait_until expires ~on time (bounded band) — the
 *      CLOCK-domain conversion trap: monotonic ns deadline must map to
 *      the platform's condattr clock (Linux) or the relative-NP fallback
 *      computed from the same monotonic source (macOS);
 *   5. cross-thread producer/consumer 1000 items zero loss through raw
 *      pthreads with strict sequence verification;
 *   6. broadcast wakes K barrier-counted waiters; signal wakes exactly
 *      one (count-gated).
 *
 * Usage: linked by tests/s3/sync/condvar/run.sh against libmojito_sys.
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

/* Monotonic reading in ns through the SAME exported clock the Mojo side
 * uses, so every elapsed measurement below shares one time domain with
 * the deadlines handed to mjs_condvar_wait_until. */
static uint64_t now_ns(void) {
    uint64_t t = 0;
    if (mjs_clock_now(&t) != 0)
        return 0;
    return t;
}

/* ---- 5/6. cross-thread fixtures --------------------------------------------- */

#define PC_ITEMS 1000
#define PC_CAP 64

typedef struct {
    mjs_condvar *cv;
    mjs_mutex *m;
    long produced; /* totals live under m (single-producer/single-
                      consumer, but kept under the lock anyway) */
    long consumed;
    long tail;
    long slots[PC_CAP];
} pc_queue_t;

static void *pc_producer(void *arg) {
    pc_queue_t *q = arg;
    for (long seq = 1; seq <= PC_ITEMS; seq++) {
        mjs_mutex_lock(q->m);
        while ((q->produced - q->consumed) == PC_CAP) {
            /* Full ring: untimed predicate wait. */
            if (mjs_condvar_wait(q->cv, q->m) != 0) {
                mjs_mutex_unlock(q->m);
                return (void *)-1;
            }
        }
        q->slots[q->tail % PC_CAP] = seq;
        q->tail++;
        q->produced++;
        mjs_condvar_signal(q->cv);
        mjs_mutex_unlock(q->m);
    }
    return NULL;
}

#define K_WAITERS 4

typedef struct {
    mjs_condvar *cv;
    mjs_mutex *m;
    atomic_int arrived; /* set to 1 under m before waiting */
    int woke;           /* nonzero once woken (.ok path taken) */
} waiter_t;

static void *gated_waiter(void *arg) {
    waiter_t *w = arg;
    mjs_mutex_lock(w->m);
    atomic_store(&w->arrived, 1);
    /* 5 s deadline in ns against the same monotonic domain the C ABI
     * normalizes deadlines to (mjs_clock_now). */
    int rc = mjs_condvar_wait_until(w->cv, w->m, now_ns() + 5000000000ULL);
    w->woke = (rc == 0);
    mjs_mutex_unlock(w->m);
    return NULL;
}

int main(void) {
    setbuf(stdout, NULL); /* unbuffered: verdicts survive any crash */

    /* ---- 1. roundtrip + consume ------------------------------------------------ */
    mjs_condvar *c = NULL;
    CHECK(mjs_condvar_init(&c) == 0 && c != NULL, "C init adopts handle");
    CHECK(mjs_condvar_signal(c) == 0, "C signal (no waiter) == 0");
    CHECK(mjs_condvar_broadcast(c) == 0, "C broadcast (no waiter) == 0");
    CHECK(mjs_condvar_destroy(&c) == 0 && c == NULL,
          "C destroy consumes (*c NULLed)");
    CHECK(mjs_condvar_destroy(&c) == -EINVAL,
          "C double destroy (*c NULLed) == -EINVAL");

    /* ---- 2. NULL / misuse contract -------------------------------------------- */
    CHECK(mjs_condvar_init(NULL) == -EFAULT, "C init(NULL) == -EFAULT");
    CHECK(mjs_condvar_signal(NULL) == -EINVAL, "C signal(NULL) == -EINVAL");
    CHECK(mjs_condvar_broadcast(NULL) == -EINVAL, "C broadcast(NULL) == -EINVAL");
    CHECK(mjs_condvar_wait(NULL, NULL) == -EINVAL, "C wait(NULL,NULL) == -EINVAL");
    CHECK(mjs_condvar_wait_until(NULL, NULL, 0) == -EINVAL,
          "C wait_until(NULL,...) == -EINVAL");
    mjs_mutex *nm = NULL;
    CHECK(mjs_condvar_init(&nm) == 0, "C init second handle");
    CHECK(mjs_condvar_destroy(&nm) == 0 && nm == NULL, "C destroy second");

    /* ---- 3/4. expiry timing through the frozen ABI ----------------------------- */
    mjs_condvar *tc = NULL;
    mjs_mutex *tm = NULL;
    CHECK(mjs_condvar_init(&tc) == 0 && mjs_mutex_init(&tm) == 0,
          "C timed-test handles");
    mjs_mutex_lock(tm);
    /* Past deadline: immediate -ETIMEDOUT, measured well under 100 ms. */
    uint64_t past = now_ns() - 1000000ULL; /* 1 ms ago */
    uint64_t t0 = now_ns();
    int rc_past = mjs_condvar_wait_until(tc, tm, past);
    uint64_t past_elapsed = now_ns() - t0;
    CHECK(rc_past == -ETIMEDOUT && past_elapsed < 100000000ULL,
          "C past-deadline == -ETIMEDOUT immediately");
    /* Future deadline: ~on time within a bounded band [110ms, 900ms]. */
    uint64_t f0 = now_ns();
    int rc_future =
        mjs_condvar_wait_until(tc, tm, f0 + 120000000ULL); /* +120 ms */
    uint64_t f_elapsed = now_ns() - f0;
    CHECK(rc_future == -ETIMEDOUT && f_elapsed >= 110000000ULL &&
              f_elapsed <= 900000000ULL,
          "C future-deadline expires ~on time (bounded)");
    mjs_mutex_unlock(tm);
    mjs_condvar_destroy(&tc);
    mjs_mutex_destroy(&tm);

    /* ---- 5. producer/consumer 1000 items zero loss ----------------------------- */
    pc_queue_t q;
    memset(&q, 0, sizeof(q));
    CHECK(mjs_condvar_init(&q.cv) == 0 && mjs_mutex_init(&q.m) == 0,
          "C pc handles");
    pthread_t prod;
    CHECK(pthread_create(&prod, NULL, pc_producer, &q) == 0,
          "C pc producer spawn");
    int pc_ok = 1;
    long consumed = 0;
    long head = 0;
    long expected = 1;
    while (consumed < PC_ITEMS) {
        mjs_mutex_lock(q.m);
        while ((q.produced - q.consumed) == 0) {
            /* Predicate loop: empty ring => bounded wait, re-check. */
            int rc = mjs_condvar_wait_until(q.cv, q.m, now_ns() + 1000000000ULL);
            (void)rc; /* .ok may be spurious; the predicate decides */
        }
        if ((q.produced - q.consumed) > 0) {
            long item = q.slots[head % PC_CAP];
            head++;
            consumed++;
            if (item != expected)
                pc_ok = 0;
            expected++;
            mjs_condvar_signal(q.cv);
        }
        q.consumed = consumed;
        mjs_mutex_unlock(q.m);
    }
    void *prod_rc = NULL;
    pthread_join(prod, &prod_rc);
    CHECK(pc_ok && prod_rc == NULL && consumed == PC_ITEMS,
          "C producer/consumer 1000 items zero loss");
    mjs_condvar_destroy(&q.cv);
    mjs_mutex_destroy(&q.m);

    /* ---- 6. broadcast K + signal exactly one ----------------------------------- */
    waiter_t ws[K_WAITERS];
    memset(ws, 0, sizeof(ws));
    mjs_condvar *wc = NULL;
    mjs_mutex *wm = NULL;
    CHECK(mjs_condvar_init(&wc) == 0 && mjs_mutex_init(&wm) == 0,
          "C wake handles");
    pthread_t wt[K_WAITERS];
    for (int i = 0; i < K_WAITERS; i++) {
        ws[i].cv = wc;
        ws[i].m = wm;
        atomic_store(&ws[i].arrived, 0);
        ws[i].woke = 0;
        pthread_create(&wt[i], NULL, gated_waiter, &ws[i]);
    }
    /* Barrier-count: poll arrivals UNDER the mutex (lost-wakeup-free). */
    for (int guard = 0; guard < 50000; guard++) {
        int all = 1;
        for (int i = 0; i < K_WAITERS; i++) {
            mjs_mutex_lock(wm);
            int a = atomic_load(&ws[i].arrived);
            mjs_mutex_unlock(wm);
            if (!a)
                all = 0;
        }
        if (all)
            break;
        usleep(200);
    }
    mjs_condvar_broadcast(wc);
    int bc_ok = 1;
    for (int i = 0; i < K_WAITERS; i++) {
        pthread_join(wt[i], NULL);
        if (!ws[i].woke)
            bc_ok = 0;
    }
    CHECK(bc_ok, "C broadcast wakes all K barrier-counted waiters");

    /* Signal exactly one: re-arm K waiters, one signal, quiet period. */
    for (int i = 0; i < K_WAITERS; i++) {
        atomic_store(&ws[i].arrived, 0);
        ws[i].woke = 0;
        pthread_create(&wt[i], NULL, gated_waiter, &ws[i]);
    }
    for (int guard = 0; guard < 50000; guard++) {
        int all = 1;
        for (int i = 0; i < K_WAITERS; i++) {
            mjs_mutex_lock(wm);
            int a = atomic_load(&ws[i].arrived);
            mjs_mutex_unlock(wm);
            if (!a)
                all = 0;
        }
        if (all)
            break;
        usleep(200);
    }
    mjs_condvar_signal(wc);
    usleep(250000); /* quiet period: exactly-one observation window */
    int woke_now = 0;
    for (int i = 0; i < K_WAITERS; i++) {
        mjs_mutex_lock(wm);
        if (ws[i].woke)
            woke_now++;
        mjs_mutex_unlock(wm);
    }
    CHECK(woke_now == 1, "C signal wakes exactly one (count-gated)");
    /* Drain the rest so their 5 s deadlines never fire. */
    while (woke_now < K_WAITERS) {
        mjs_condvar_broadcast(wc);
        usleep(50000);
        woke_now = 0;
        for (int i = 0; i < K_WAITERS; i++) {
            mjs_mutex_lock(wm);
            if (ws[i].woke)
                woke_now++;
            mjs_mutex_unlock(wm);
        }
    }
    int sg_ok = (woke_now == K_WAITERS);
    for (int i = 0; i < K_WAITERS; i++) {
        void *jrc = NULL;
        pthread_join(wt[i], &jrc);
        if (jrc != NULL)
            sg_ok = 0;
    }
    CHECK(sg_ok, "C drain completes without lost sleepers");
    mjs_condvar_destroy(&wc);
    mjs_mutex_destroy(&wm);

    if (failures == 0) {
        printf("condvar-c-smoke: ALL PASS\n");
        return 0;
    }
    printf("condvar-c-smoke: %d FAILURE(S)\n", failures);
    return 1;
}
