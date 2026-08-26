/* mojito-sys S3.5 — native C smoke for the mjs_event_* surface (issue #61).
 *
 * Pins the frozen s3-event ABI contract directly against
 * libmojito_sys.dylib (the link makes a missing export a hard failure):
 *
 *   1. init/wait/signal roundtrip + consume-on-destroy;
 *   2. NULL/out-slot contract: init(NULL) == -EFAULT, any primitive on
 *      a NULL handle == -EINVAL;
 *   3. AUTO-RESET semantics through the raw ABI: pre-signal sticks for
 *      exactly ONE wait (immediate), extra signals COALESCE (second
 *      wait hits -ETIMEDOUT on a short deadline);
 *   4. wait_until expiry: past deadline == -ETIMEDOUT immediately
 *      (measured); future deadline expires ~on time in a bounded band;
 *   5. cross-thread breadth-one: K gated waiters, ONE signal wakes
 *      EXACTLY one (counted over a quiet period); K-1 further signals
 *      drain the rest;
 *   6. lost-wakeup regression: 2000 signal/wait cycles where the
 *      signal races the waiter's park — every cycle must complete
 *      within its deadline (never hangs).
 *
 * Usage: linked by tests/s3/sync/event/run.sh against libmojito_sys.
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

/* Monotonic reading in ns through the SAME exported clock the Mojo
 * side uses, so deadlines share one time domain across the ABI. */
static uint64_t now_ns(void) {
    uint64_t t = 0;
    if (mjs_clock_now(&t) != 0)
        return 0;
    return t;
}

/* ---- cross-thread fixtures --------------------------------------------------- */

#define K_WAITERS 4

typedef struct {
    mjs_event *e;
    atomic_int arrived; /* set before a settle delay, then park */
    int woke;           /* nonzero once a wait returned 0 */
    int rc;             /* raw wait rc */
} waiter_t;

static void *gated_waiter(void *arg) {
    waiter_t *w = arg;
    atomic_store(&w->arrived, 1);
    /* Settle delay so the spawner observes `arrived` only after the
     * waiter is (overwhelmingly) asleep inside the event. */
    usleep(100000);
    w->rc = mjs_event_wait_until(w->e, now_ns() + 5000000000ULL);
    w->woke = (w->rc == 0);
    return NULL;
}

#define LW_CYCLES 2000

typedef struct {
    mjs_event *sig; /* pings: spawner -> waiter */
    mjs_event *ack; /* acks: waiter -> spawner */
    long cycles;
    long timeouts; /* any -ETIMEDOUT here is a LOST WAKEUP */
    int failed;
} looper_t;

/* PING-PONG SHAPE (why an ack exists): the documented semantics
 * COALESCE signals issued while a token is pending, so a blind signal
 * barrage could legitimately under-count wakes. Each cycle is
 * acknowledged before the next ping fires — and because the spawner
 * re-signals the instant the ack lands, the ping still routinely
 * races this loop between its predicate check and its sleep. */
static void *ping_waiter(void *arg) {
    looper_t *l = arg;
    for (long i = 0; i < l->cycles; i++) {
        int rc = mjs_event_wait_until(l->sig, now_ns() + 5000000000ULL);
        if (rc == -ETIMEDOUT) {
            l->timeouts++;
            return NULL;
        } else if (rc != 0) {
            l->failed = 1;
            return NULL;
        }
        mjs_event_signal(l->ack);
    }
    return NULL;
}

int main(void) {
    setbuf(stdout, NULL); /* unbuffered: verdicts survive any crash */

    /* ---- 1. roundtrip + consume ------------------------------------------------ */
    mjs_event *e = NULL;
    CHECK(mjs_event_init(&e) == 0 && e != NULL, "C init adopts handle");
    CHECK(mjs_event_signal(e) == 0, "C signal (no waiter) == 0");
    CHECK(mjs_event_destroy(&e) == 0 && e == NULL,
          "C destroy consumes (*e NULLed)");
    CHECK(mjs_event_destroy(&e) == -EINVAL,
          "C double destroy (*e NULLed) == -EINVAL");

    /* ---- 2. NULL / misuse contract -------------------------------------------- */
    CHECK(mjs_event_init(NULL) == -EFAULT, "C init(NULL) == -EFAULT");
    CHECK(mjs_event_signal(NULL) == -EINVAL, "C signal(NULL) == -EINVAL");
    CHECK(mjs_event_wait(NULL) == -EINVAL, "C wait(NULL) == -EINVAL");
    CHECK(mjs_event_wait_until(NULL, 0) == -EINVAL,
          "C wait_until(NULL,...) == -EINVAL");
    mjs_event *ne = NULL;
    CHECK(mjs_event_init(&ne) == 0, "C init second handle");
    CHECK(mjs_event_destroy(&ne) == 0 && ne == NULL, "C destroy second");

    /* ---- 3. auto-reset: stick-once + coalesce ---------------------------------- */
    mjs_event *ae = NULL;
    CHECK(mjs_event_init(&ae) == 0, "C auto-reset handle");
    CHECK(mjs_event_signal(ae) == 0, "C pre-signal stores token");
    uint64_t t0 = now_ns();
    CHECK(mjs_event_wait(ae) == 0 && now_ns() - t0 < 100000000ULL,
          "C first wait consumes token immediately");
    /* Signals coalesced while nothing waited: only ONE token existed. */
    CHECK(mjs_event_signal(ae) == 0 && mjs_event_signal(ae) == 0 &&
              mjs_event_signal(ae) == 0,
          "C three more signals");
    CHECK(mjs_event_wait(ae) == 0, "C next wait consumes the single token");
    CHECK(mjs_event_wait_until(ae, now_ns()) == -ETIMEDOUT,
          "C coalesced extras did not queue (past-dl -ETIMEDOUT)");
    mjs_event_destroy(&ae);

    /* ---- 4. expiry timing through the frozen ABI -------------------------------- */
    mjs_event *te = NULL;
    CHECK(mjs_event_init(&te) == 0, "C timed-test handle");
    uint64_t past = now_ns() - 1000000ULL; /* 1 ms ago */
    t0 = now_ns();
    int rc_past = mjs_event_wait_until(te, past);
    uint64_t past_elapsed = now_ns() - t0;
    CHECK(rc_past == -ETIMEDOUT && past_elapsed < 100000000ULL,
          "C past-deadline == -ETIMEDOUT immediately");
    uint64_t f0 = now_ns();
    int rc_future = mjs_event_wait_until(te, f0 + 120000000ULL); /* +120 ms */
    uint64_t f_elapsed = now_ns() - f0;
    CHECK(rc_future == -ETIMEDOUT && f_elapsed >= 110000000ULL &&
              f_elapsed <= 900000000ULL,
          "C future-deadline expires ~on time (bounded)");
    mjs_event_destroy(&te);

    /* ---- 5. breadth-one: one signal, exactly one wake --------------------------- */
    waiter_t ws[K_WAITERS];
    memset(ws, 0, sizeof(ws));
    mjs_event *we = NULL;
    CHECK(mjs_event_init(&we) == 0, "C wake handle");
    pthread_t wt[K_WAITERS];
    for (int i = 0; i < K_WAITERS; i++) {
        ws[i].e = we;
        pthread_create(&wt[i], NULL, gated_waiter, &ws[i]);
    }
    /* Barrier-count arrivals (settle delays make this hang-free). */
    for (int guard = 0; guard < 50000; guard++) {
        int all = 1;
        for (int i = 0; i < K_WAITERS; i++)
            if (!atomic_load(&ws[i].arrived))
                all = 0;
        if (all)
            break;
        usleep(200);
    }
    usleep(150000); /* let every waiter reach its sleep */
    mjs_event_signal(we); /* ONE token */
    usleep(250000);       /* quiet period: exactly-one observation window */
    int woke_now = 0;
    for (int i = 0; i < K_WAITERS; i++)
        if (ws[i].woke)
            woke_now++;
    CHECK(woke_now == 1, "C one signal wakes EXACTLY one of K waiters");
    /* Drain the rest: one signal per remaining sleeper. */
    int drained = woke_now;
    for (int guard = 0; guard < 200 && drained < K_WAITERS; guard++) {
        mjs_event_signal(we);
        usleep(50000);
        drained = 0;
        for (int i = 0; i < K_WAITERS; i++)
            if (ws[i].woke)
                drained++;
    }
    int sg_ok = (drained == K_WAITERS);
    for (int i = 0; i < K_WAITERS; i++) {
        void *jrc = NULL;
        pthread_join(wt[i], &jrc);
        if (ws[i].rc != 0)
            sg_ok = 0;
    }
    CHECK(sg_ok, "C K-1 further signals drain every remaining waiter");
    mjs_event_destroy(&we);

    /* ---- 6. lost-wakeup regression: racing signal/park never hangs -------------- */
    mjs_event *le = NULL;
    mjs_event *acke = NULL;
    CHECK(mjs_event_init(&le) == 0 && mjs_event_init(&acke) == 0,
          "C lost-wakeup handles");
    static looper_t lp;
    memset(&lp, 0, sizeof(lp));
    lp.sig = le;
    lp.ack = acke;
    lp.cycles = LW_CYCLES;
    pthread_t lt;
    CHECK(pthread_create(&lt, NULL, ping_waiter, &lp) == 0,
          "C ping waiter spawn");
    /* Ping-pong: each ack re-arms the next ping IMMEDIATELY, so the
     * signal keeps racing the waiter's park. A lost wakeup in either
     * interleaving would surface as lp.timeouts > 0 (deadline hit). */
    long ack_timeouts = 0;
    for (int i = 0; i < LW_CYCLES; i++) {
        mjs_event_signal(le);
        if (mjs_event_wait_until(acke, now_ns() + 5000000000ULL) ==
            -ETIMEDOUT)
            ack_timeouts++;
    }
    pthread_join(lt, NULL);
    CHECK(lp.timeouts == 0 && !lp.failed && lp.cycles == LW_CYCLES &&
              ack_timeouts == 0,
          "C 2000 racing signal/wait cycles, zero lost wakeups");
    mjs_event_destroy(&le);
    mjs_event_destroy(&acke);

    if (failures == 0) {
        printf("event-c-smoke: ALL PASS\n");
        return 0;
    }
    printf("event-c-smoke: %d FAILURE(S)\n", failures);
    return 1;
}
