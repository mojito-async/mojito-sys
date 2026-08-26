/* mojito-sys S3.3 — native C smoke for the mjs_atomic_* surface (issue #59).
 *
 * Pins the frozen s3-atomic-wait ABI contract directly against
 * libmojito_sys.dylib (the link makes a missing export a hard failure):
 *
 *   1. NULL-address contract: every entry point == -EFAULT;
 *   2. backend-parameterized like the Mojo suite: a probe wait whose word
 *      mismatches identifies a live backend (.ok path) vs the documented
 *      -ENOSYS stub host (unsupported-backend mode, clean red-exclusion
 *      for the macOS fallback lane #60);
 *   3. on a live backend: mismatch-immediate 0; unmet deadline ==
 *      -ETIMEDOUT after >= the requested span; wake accounting EXACTLY
 *      0 / 1 / N with parked pthreads; two-thread ping-pong with every
 *      wait deadline-bounded (zero hangs by construction).
 *
 * Deadline arithmetic uses mjs_clock_now (the ABI's monotonic ns clock),
 * mirroring what callers do upstream.
 */
#include "mojito_sys.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
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

#define NS_PER_MS 1000000ULL

static uint64_t now_ns(void) {
    uint64_t t = 0;
    if (mjs_clock_now(&t) != 0)
        return 0;
    return t;
}

static uint64_t abs_deadline_ms(long ms) {
    return now_ns() + (uint64_t)ms * NS_PER_MS;
}

/* Waiter: bumps its own ready slot, then parks on *word == expected with
 * a bounded deadline. arg layout:
 *   [0] word addr  [1] expected  [2] status (0 ok / -1 else)
 *   [3] ready slot addr  [4] timeout ms */
typedef struct {
    uint64_t cells[5];
} waiter_arg_t;

static void *waiter_main(void *arg) {
    waiter_arg_t *a = arg;
    uint32_t *w = (uint32_t *)(uintptr_t)a->cells[0];
    uint32_t expected = (uint32_t)a->cells[1];
    atomic_ullong *ready = (atomic_ullong *)(uintptr_t)a->cells[3];
    uint64_t deadline = abs_deadline_ms((long)a->cells[4]);
    atomic_store_explicit(ready, 1, memory_order_release);
    int rc = mjs_atomic_wait_on_u32(w, expected, &deadline);
    unsigned long long st =
        rc == 0 ? 0 : (unsigned long long)-1;
    atomic_store_explicit((atomic_ullong *)&a->cells[2], st,
                          memory_order_release);
    return NULL;
}

/* Ping-pong workers: flip the shared turn word to the peer ROUNDS times,
 * waking it each flip. Every wait is individually deadline-bounded, so a
 * lost wake surfaces as a nonzero exit status, never a hang. */
#define PING_ROUNDS 1000

typedef struct {
    _Atomic uint32_t *turn; /* cast to plain uint32_t* at the ABI edge */
    int my_turn;
    int rounds;
} ping_arg_t;

static void *ping_main(void *arg) {
    ping_arg_t *pa = arg;
    const uint32_t *turn = (const uint32_t *)(uintptr_t)pa->turn;
    for (int i = 0; i < pa->rounds; i++) {
        uint64_t dl = abs_deadline_ms(30000);
        int rc = mjs_atomic_wait_on_u32(turn, (uint32_t)pa->my_turn, &dl);
        if (rc != 0 ||
            atomic_load_explicit(pa->turn, memory_order_acquire) !=
                (uint32_t)pa->my_turn)
            return (void *)(intptr_t)-1;
        atomic_store_explicit(
            pa->turn, (uint32_t)(1 - pa->my_turn), memory_order_release);
        if (mjs_atomic_wake_one_u32((uint32_t *)(uintptr_t)pa->turn) < 0)
            return (void *)(intptr_t)-1;
    }
    return NULL;
}

int main(void) {
    setbuf(stdout, NULL); /* unbuffered: verdicts survive any crash */

    /* ---- 1. NULL contract --------------------------------------------------- */
    CHECK(mjs_atomic_wait_on_u32(NULL, 0, NULL) == -EFAULT,
          "C wait(NULL) == -EFAULT");
    CHECK(mjs_atomic_wake_one_u32(NULL) == -EFAULT,
          "C wake_one(NULL) == -EFAULT");
    CHECK(mjs_atomic_wake_all_u32(NULL) == -EFAULT,
          "C wake_all(NULL) == -EFAULT");

    /* ---- 2. backend probe ------------------------------------------------------ */
    uint32_t w = 2;
    uint64_t probe_dl = abs_deadline_ms(50);
    int probe_rc = mjs_atomic_wait_on_u32(&w, 1, &probe_dl);
    int have_backend = (probe_rc == 0); /* EAGAIN -> documented ok */
    printf("backend=%s\n", have_backend ? "present" : "absent (-ENOSYS)");

    if (!have_backend) {
        /* Unsupported-backend mode: deterministic, immediate, no sleeps. */
        int want = -ENOSYS;
        CHECK(mjs_atomic_wait_on_u32(&w, 9, &probe_dl) == want,
              "C absent backend: wait == -ENOSYS");
        CHECK(mjs_atomic_wake_one_u32(&w) == want,
              "C absent backend: wake_one == -ENOSYS");
        CHECK(mjs_atomic_wake_all_u32(&w) == want,
              "C absent backend: wake_all == -ENOSYS");
        if (failures == 0) {
            printf("RESULT: all green\n");
            return 0;
        }
        printf("RESULT: %d FAILED\n", failures);
        return 1;
    }

    /* ---- 3. mismatch -> immediate success status --------------------------------- */
    w = 2;
    uint64_t far_dl = abs_deadline_ms(2000);
    uint64_t t0 = now_ns();
    int rc = mjs_atomic_wait_on_u32(&w, 1, &far_dl);
    uint64_t took_ms = (now_ns() - t0) / NS_PER_MS;
    CHECK(rc == 0 && took_ms < 1000 && w == 2,
          "C mismatch returns immediately without sleeping");

    /* ---- 4. expired deadline -> -ETIMEDOUT ----------------------------------------- */
    w = 7;
    uint64_t short_dl = abs_deadline_ms(60);
    t0 = now_ns();
    rc = mjs_atomic_wait_on_u32(&w, 7, &short_dl);
    took_ms = (now_ns() - t0) / NS_PER_MS;
    CHECK(rc == -ETIMEDOUT && took_ms >= 55,
          "C unmet wait hits -ETIMEDOUT after ~the span");

    /* ---- 5. wake accounting: zero waiters ------------------------------------------- */
    w = 5;
    CHECK(mjs_atomic_wake_one_u32(&w) == 0, "C wake_one no waiter == 0");
    CHECK(mjs_atomic_wake_all_u32(&w) == 0, "C wake_all no waiter == 0");

    /* ---- 6. wake accounting: exactly one ---------------------------------------------- */
    waiter_arg_t one;
    memset(&one, 0, sizeof one);
    one.cells[0] = (uint64_t)(uintptr_t)&w;
    one.cells[1] = 5;
    one.cells[2] = (uint64_t)-99;
    one.cells[4] = 30000;
    atomic_ullong one_ready = 0;
    one.cells[3] = (uint64_t)(uintptr_t)&one_ready;
    pthread_t one_tid;
    int spawned = pthread_create(&one_tid, NULL, waiter_main, &one) == 0;
    while (spawned &&
           atomic_load_explicit(&one_ready, memory_order_acquire) == 0)
        usleep(100);
    usleep(150 * 1000); /* settle window */
    long woke = mjs_atomic_wake_one_u32(&w);
    int joined = spawned && pthread_join(one_tid, NULL) == 0;
    CHECK(spawned && joined && woke == 1 &&
              atomic_load_explicit((atomic_ullong *)&one.cells[2],
                                   memory_order_acquire) == 0,
          "C wake_one with one parked waiter == exactly 1");

    /* ---- 7. wake accounting: exactly N -------------------------------------------------- */
    enum { N = 4 };
    pthread_t tids[N];
    waiter_arg_t args[N];
    atomic_ullong ready[N];
    memset(args, 0, sizeof args);
    memset(ready, 0, sizeof ready);
    spawned = 1;
    for (int i = 0; i < N; i++) {
        args[i].cells[0] = (uint64_t)(uintptr_t)&w;
        args[i].cells[1] = 5;
        args[i].cells[2] = (uint64_t)-99;
        args[i].cells[3] = (uint64_t)(uintptr_t)&ready[i];
        args[i].cells[4] = 30000;
        if (pthread_create(&tids[i], NULL, waiter_main, &args[i]) != 0)
            spawned = 0;
    }
    if (spawned) {
        int all_ready;
        do {
            all_ready = 1;
            for (int i = 0; i < N; i++)
                if (atomic_load_explicit(&ready[i], memory_order_acquire) == 0)
                    all_ready = 0;
        } while (!all_ready && usleep(100) == 0);
        usleep(150 * 1000); /* settle window */
    }
    long woke_n = mjs_atomic_wake_all_u32(&w);
    int statuses_ok = spawned;
    for (int i = 0; i < N; i++) {
        if (pthread_join(tids[i], NULL) != 0 ||
            atomic_load_explicit((atomic_ullong *)&args[i].cells[2],
                                 memory_order_acquire) != 0)
            statuses_ok = 0;
    }
    CHECK(spawned && woke_n == N && statuses_ok,
          "C wake_all with N parked waiters == exactly N");

    /* ---- 8. cross-thread ping-pong, deadline-guarded --------------------------------------- */
    static _Atomic uint32_t turn;
    atomic_store_explicit(&turn, 0, memory_order_relaxed);
    ping_arg_t pa[2] = {{&turn, 0, PING_ROUNDS}, {&turn, 1, PING_ROUNDS}};
    pthread_t pt[2];
    int pp_spawned =
        pthread_create(&pt[0], NULL, ping_main, &pa[0]) == 0 &&
        pthread_create(&pt[1], NULL, ping_main, &pa[1]) == 0;
    void *r0 = NULL, *r1 = NULL;
    int pp_joined = pp_spawned && pthread_join(pt[0], &r0) == 0 &&
                    pthread_join(pt[1], &r1) == 0;
    CHECK(pp_spawned && pp_joined && r0 == NULL && r1 == NULL &&
              atomic_load_explicit(&turn, memory_order_acquire) == 0,
          "C ping-pong 1000 x 1000 rounds, zero hangs");

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d FAILED\n", failures);
    return 1;
}
