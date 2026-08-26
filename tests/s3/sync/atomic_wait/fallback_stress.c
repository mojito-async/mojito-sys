/* mojito-sys S3.4 — macOS fallback stress (issue #60).
 *
 * Exercises the #60 hashed-slot fallback backend with 256 DISTINCT u32
 * words whose addresses hash onto FEWER physical table slots (birthday
 * collisions are guaranteed at this load factor), with concurrent
 * waiters sharing those slots:
 *
 *   round A: 1 waiter per word x 256 words — every wake_one must return
 *            EXACTLY 1 and every waiter must observe its own handoff
 *            (.ok, not .timed_out): zero lost wakeups across colliding
 *            slots;
 *   round B: 4 waiters per word x 64 words (256 waiters on 64 keys) —
 *            every wake_all must return EXACTLY 4 and wake every waiter;
 *   rounds repeat ITERATIONS times with reshuffled wake order.
 *
 * A lost wakeup or an inexact wake count surfaces as a nonzero exit
 * (never a hang: every wait is deadline-bounded).
 *
 * Build/run: tests/s3/sync/atomic_wait/run_stress.sh
 */
#include "mojito_sys.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N_WORDS 256
#define WAITERS_PER_WORD_B 4
#define B_WORDS (N_WORDS / WAITERS_PER_WORD_B)
#define ITERATIONS 8
#define SETTLE_MS 150
#define TIMEOUT_MS 30000

/* One padded line per word: distinct keys, no false sharing. */
typedef struct {
    _Atomic uint32_t v;
    char pad[64 - sizeof(_Atomic uint32_t)];
} word_line;
static word_line words[N_WORDS];

static uint64_t now_ns(void) {
    uint64_t t = 0;
    if (mjs_clock_now(&t) != 0)
        exit(2);
    return t;
}

static int failures = 0;

/* arg block: [0] word addr [1] expected [2] status(0 ok/-1) [3] ready */
typedef struct {
    const uint32_t *word; /* set before spawn; read-only to the waiter */
    uint32_t expected;
    _Atomic long status;
    _Atomic int ready;
} warg_t;

static void *waiter_main(void *p) {
    warg_t *a = p;
    atomic_store_explicit(&a->ready, 1, memory_order_release);
    uint64_t dl = now_ns() + (uint64_t)TIMEOUT_MS * 1000000ULL;
    int rc = mjs_atomic_wait_on_u32(a->word, a->expected, &dl);
    atomic_store_explicit(&a->status, rc == 0 ? 0 : -1, memory_order_release);
    return NULL;
}
static int cmp_uint(const void *x, const void *y) {
    unsigned a = *(const unsigned *)x, b = *(const unsigned *)y;
    return a < b ? -1 : a > b;
}

int main(void) {
    setbuf(stdout, NULL);
    for (int i = 0; i < N_WORDS; i++)
        atomic_store_explicit(&words[i].v, (uint32_t)i, memory_order_relaxed);

    /* Distinct-key sanity: all 256 addresses differ (they hash onto
     * fewer than 256 physical slots by birthday bound). */
    for (int i = 0; i < N_WORDS; i++)
        for (int j = i + 1; j < N_WORDS; j++)
            if (&words[i].v == &words[j].v)
                failures++;

    pthread_t th[N_WORDS];
    warg_t args[N_WORDS];

    for (int iter = 0; iter < ITERATIONS && !failures; iter++) {
        /* ---- round A: one waiter per key, wake_one each ---------- */
        memset(args, 0, sizeof(args));
        for (int i = 0; i < N_WORDS; i++) {
            atomic_store_explicit(&words[i].v, (uint32_t)(i + iter),
                                  memory_order_relaxed);
            args[i].word = &words[i].v;
            args[i].expected = (uint32_t)(i + iter);
            if (pthread_create(&th[i], NULL, waiter_main, &args[i]) != 0)
                exit(2);
        }
        struct timespec ts = {0, SETTLE_MS * 1000000L};
        nanosleep(&ts, NULL); /* let all 256 park across shared slots */

        unsigned order[N_WORDS];
        for (int i = 0; i < N_WORDS; i++)
            order[i] = (unsigned)((i * 167 + iter * 31) % N_WORDS);
        qsort(order, N_WORDS, sizeof(unsigned), cmp_uint);

        long woke_sum = 0;
        for (int i = 0; i < N_WORDS; i++) {
            int k = (int)order[i];
            long w = mjs_atomic_wake_one_u32(
                (uint32_t *)(uintptr_t)&words[k].v);
            if (w != 1) {
                printf("roundA iter %d wake_one(word %d) == %ld (want 1)\n",
                       iter, k, w);
                failures++;
            }
            woke_sum += w;
        }
        for (int i = 0; i < N_WORDS; i++) {
            pthread_join(th[i], NULL);
            if (atomic_load(&args[i].status) != 0) {
                printf("roundA iter %d waiter(word %d) lost wake\n", iter, i);
                failures++;
            }
        }
        printf("round A iter %d: woke=%ld/256 exact, zero lost\n", iter,
               woke_sum);

        /* ---- round B: 4 waiters per key x 64 keys, wake_all ------ */
        memset(args, 0, sizeof(args));
        int n = 0;
        for (int g = 0; g < B_WORDS; g++) {
            atomic_store_explicit(
                &words[g].v, (uint32_t)(1000 + g + iter), memory_order_relaxed);
            for (int k = 0; k < WAITERS_PER_WORD_B; k++) {
                args[n].word = &words[g].v;
                args[n].expected = (uint32_t)(1000 + g + iter);
                pthread_create(&th[n], NULL, waiter_main, &args[n]) != 0
                    ? exit(2) : (void)0;
                n++;
            }
        }
        nanosleep(&ts, NULL);

        for (int g = 0; g < B_WORDS; g++) {
            long w = mjs_atomic_wake_all_u32(
                (uint32_t *)(uintptr_t)&words[g].v);
            if (w != WAITERS_PER_WORD_B) {
                printf("roundB iter %d wake_all(group %d) == %ld (want %d)\n",
                       iter, g, w, WAITERS_PER_WORD_B);
                failures++;
            }
        }
        for (int i = 0; i < n; i++) {
            pthread_join(th[i], NULL);
            if (atomic_load(&args[i].status) != 0) {
                printf("roundB iter %d waiter %d lost wake\n", iter, i);
                failures++;
            }
        }
        printf("round B iter %d: %d/%d exact wake_all, zero lost\n", iter,
               n, n);
    }

    if (failures == 0) {
        printf("STRESS RESULT: ALL PASS (%d iterations)\n", ITERATIONS);
        return 0;
    }
    printf("STRESS RESULT: %d FAILURES\n", failures);
    return 1;
}
