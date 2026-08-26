/* mojito-sys S3.7 — native C smoke for the mjs_sem_* surface (issue #106).
 *
 * Pins the frozen s3-semaphore ABI contract directly against
 * libmojito_sys.dylib (the link makes a missing export a hard failure,
 * so this suite stays red until native/posix/mjs_sem.c lands):
 *
 *   1. init/post/wait roundtrip + consume-on-destroy + double-destroy;
 *   2. NULL/out-slot/negative-init contract:
 *      init(NULL) == -EFAULT, init(negative) == -EINVAL, any primitive
 *      on a NULL handle == -EINVAL;
 *   3. try_wait NON-BLOCKING: -EBUSY when empty, 0 after post, -EBUSY
 *      again once the permit is consumed;
 *   4. past-deadline wait_until == -ETIMEDOUT immediately (measured);
 *   5. future-deadline wait_until expires ~on time (bounded band) — the
 *      CLOCK-domain conversion trap shared with the condvar layer;
 *   6. MULTI-PERMIT accumulation: N=5 posts with nobody waiting leave
 *      FIVE permits, so exactly N later waits each consume one and a
 *      try_wait finds the semaphore depleted (no coalescing);
 *   7. cross-thread P/V balance: producer posts P=1000 permits, a
 *      consumer waits them all with zero loss; a blocked waiter is
 *      released by a post and no count ever goes negative.
 *
 * Usage: linked by tests/s3/sync/semaphore/run.sh against libmojito_sys.
 */
#include "mojito_sys.h"

#include <pthread.h>
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
 * the deadlines handed to mjs_sem_wait_until. */
static uint64_t now_ns(void) {
    uint64_t t = 0;
    if (mjs_clock_now(&t) != 0)
        return 0;
    return t;
}

/* ---- 7. cross-thread fixtures --------------------------------------------- */

#define PV_PERMITS 1000

typedef struct {
    mjs_sem *s;
    long posted; /* totals guarded by nothing (single-writer after spawn) */
    long consumed;
} pv_t;

static void *pv_producer(void *arg) {
    pv_t *q = arg;
    for (long i = 0; i < PV_PERMITS; i++) {
        if (mjs_sem_post(q->s) != 0)
            return (void *)-1;
    }
    q->posted = PV_PERMITS;
    return NULL;
}

typedef struct {
    mjs_sem *s;
    int arrived;
    int woke;
} gated_t;

static void *gated_waiter(void *arg) {
    gated_t *g = arg;
    __atomic_store_n(&g->arrived, 1, __ATOMIC_SEQ_CST);
    /* 5 s deadline in ns against the same monotonic domain the C ABI
     * normalizes deadlines to (mjs_clock_now). */
    int rc = mjs_sem_wait_until(g->s, now_ns() + 5000000000ULL);
    g->woke = (rc == 0);
    return NULL;
}

int main(void) {
    setbuf(stdout, NULL); /* unbuffered: verdicts survive any crash */

    /* ---- 1. roundtrip + consume ------------------------------------------------ */
    mjs_sem *s = NULL;
    CHECK(mjs_sem_init(0, &s) == 0 && s != NULL, "C init(0) adopts handle");
    mjs_sem_post(s);
    CHECK(mjs_sem_wait(s) == 0, "C post/wait roundtrip == 0");
    CHECK(mjs_sem_destroy(&s) == 0 && s == NULL,
          "C destroy consumes (*s NULLed)");
    CHECK(mjs_sem_destroy(&s) == -EINVAL,
          "C double destroy (*s NULLed) == -EINVAL");

    /* ---- 2. NULL / misuse contract -------------------------------------------- */
    CHECK(mjs_sem_init(0, NULL) == -EFAULT, "C init(NULL) == -EFAULT");
    mjs_sem *neg = NULL;
    CHECK(mjs_sem_init(-1, &neg) == -EINVAL && neg == NULL,
          "C init(negative) == -EINVAL (count never negative)");
    CHECK(mjs_sem_post(NULL) == -EINVAL, "C post(NULL) == -EINVAL");
    CHECK(mjs_sem_wait(NULL) == -EINVAL, "C wait(NULL) == -EINVAL");
    CHECK(mjs_sem_wait_until(NULL, 0) == -EINVAL,
          "C wait_until(NULL,...) == -EINVAL");
    CHECK(mjs_sem_try_wait(NULL) == -EINVAL, "C try_wait(NULL) == -EINVAL");

    /* ---- 3. try_wait NON-BLOCKING logic --------------------------------------- */
    mjs_sem *ts = NULL;
    CHECK(mjs_sem_init(0, &ts) == 0, "C try-test handle");
    CHECK(mjs_sem_try_wait(ts) == -EBUSY, "C try_wait(empty) == -EBUSY");
    mjs_sem_post(ts);
    CHECK(mjs_sem_try_wait(ts) == 0, "C try_wait(after post) == 0");
    CHECK(mjs_sem_try_wait(ts) == -EBUSY, "C try_wait(consumed) == -EBUSY");
    mjs_sem_destroy(&ts);

    /* ---- 4/5. expiry timing through the frozen ABI ----------------------------- */
    mjs_sem *tc = NULL;
    CHECK(mjs_sem_init(0, &tc) == 0, "C timed-test handle");
    /* Past deadline: immediate -ETIMEDOUT, measured well under 100 ms. */
    uint64_t past = now_ns() - 1000000ULL; /* 1 ms ago */
    uint64_t t0 = now_ns();
    int rc_past = mjs_sem_wait_until(tc, past);
    uint64_t past_elapsed = now_ns() - t0;
    CHECK(rc_past == -ETIMEDOUT && past_elapsed < 100000000ULL,
          "C past-deadline == -ETIMEDOUT immediately");
    /* Future deadline: ~on time within a bounded band [110ms, 900ms]. */
    uint64_t f0 = now_ns();
    int rc_future = mjs_sem_wait_until(tc, f0 + 120000000ULL); /* +120 ms */
    uint64_t f_elapsed = now_ns() - f0;
    CHECK(rc_future == -ETIMEDOUT && f_elapsed >= 110000000ULL &&
              f_elapsed <= 900000000ULL,
          "C future-deadline expires ~on time (bounded)");
    mjs_sem_destroy(&tc);

    /* ---- 6. MULTI-PERMIT accumulation (no coalescing) -------------------------- */
    mjs_sem *ms = NULL;
    CHECK(mjs_sem_init(0, &ms) == 0, "C multi handle");
    for (int i = 0; i < 5; i++)
        mjs_sem_post(ms); /* five permits, nobody waiting */
    int multi_ok = 1;
    for (int i = 0; i < 5; i++) {
        if (mjs_sem_wait(ms) != 0)
            multi_ok = 0;
    }
    CHECK(multi_ok && mjs_sem_try_wait(ms) == -EBUSY,
          "C 5 posts release exactly 5 waits; then depleted (-EBUSY)");
    mjs_sem_destroy(&ms);

    /* ---- 7. cross-thread P/V balance ------------------------------------------- */
    pv_t q;
    memset(&q, 0, sizeof(q));
    CHECK(mjs_sem_init(0, &q.s) == 0, "C pv handle");
    pthread_t prod;
    CHECK(pthread_create(&prod, NULL, pv_producer, &q) == 0,
          "C pv producer spawn");
    int pv_ok = 1;
    for (long i = 0; i < PV_PERMITS; i++) {
        /* Bounded per-wait so a lost wake / over-consumption surfaces as
         * a timeout instead of a hang; the business total is exact. */
        int rc = mjs_sem_wait_until(q.s, now_ns() + 5000000000ULL);
        if (rc != 0) {
            pv_ok = 0;
            break;
        }
        q.consumed++;
    }
    void *prod_rc = NULL;
    pthread_join(prod, &prod_rc);
    CHECK(pv_ok && prod_rc == NULL && q.consumed == PV_PERMITS &&
              q.posted == PV_PERMITS,
          "C P/V balance: 1000 posts, 1000 waits, zero loss");
    mjs_sem_destroy(&q.s);

    /* Blocked waiter released by a post (gated arrival, prompt). */
    mjs_sem *gs = NULL;
    CHECK(mjs_sem_init(0, &gs) == 0, "C gated handle");
    gated_t g;
    g.s = gs;
    __atomic_store_n(&g.arrived, 0, __ATOMIC_SEQ_CST);
    g.woke = 0;
    pthread_t gw;
    pthread_create(&gw, NULL, gated_waiter, &g);
    for (int guard = 0; guard < 50000; guard++) {
        if (__atomic_load_n(&g.arrived, __ATOMIC_SEQ_CST))
            break;
        usleep(200);
    }
    mjs_sem_post(gs);
    void *gr = NULL;
    pthread_join(gw, &gr);
    CHECK(g.woke && gr == NULL, "C blocked waiter released by cross-thread post");
    mjs_sem_destroy(&gs);

    if (failures == 0) {
        printf("sem-c-smoke: ALL PASS\n");
        return 0;
    }
    printf("sem-c-smoke: %d FAILURE(S)\n", failures);
    return 1;
}