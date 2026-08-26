/* mojito-sys S2.3 — native TLS key layer smoke (issue #50).
 *
 * Links against libmojito_sys.dylib and exercises the CORE mjs_tls_* ops
 * single-threaded, plus destructor-exactly-once via a plain pthread spawned
 * here (this tests the C layer; the mjs_thread wrapper is S2.1/#48):
 *   - create(destructor may be NULL) mints distinct nonzero keys;
 *   - get(unset) is NULL with NO allocation (SYS-4 names TLS reads);
 *   - set/get round-trip + overwrite + two-key isolation on one thread;
 *   - set/get/destroy with a bad key: -EINVAL / NULL / -EINVAL;
 *   - destroy-then-set -EINVAL, double destroy -EINVAL, get-after NULL;
 *   - out_key UNTOUCHED on a failed create (exhaust the pthread key pool);
 *   - destructor fires EXACTLY ONCE at thread exit with the stored value.
 *
 * The full isolation/reuse/destructor-once conformance over spawned
 * mjs_threads lives in tests/s2/conformance/tls/conformance.mojo (issue
 * #54, spec L1850).
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "mojito_sys.h"

static int g_failures;

#define CHECK(cond, name)                                                  \
    do {                                                                   \
        if (cond) {                                                        \
            printf("  ok   %s\n", (name));                                 \
        } else {                                                           \
            printf("  FAIL %s\n", (name));                                 \
            g_failures++;                                                  \
        }                                                                  \
    } while (0)

/* --- destructor instrumentation ----------------------------------------- */
static atomic_int g_dtor_calls;
static void *g_dtor_seen;

static void counting_dtor(void *value) {
    atomic_fetch_add_explicit(&g_dtor_calls, 1, memory_order_acq_rel);
    g_dtor_seen = value;
}

/* Worker: store payload in TLS, then leave via pthread_exit so the
 * destructor must fire exactly once before join returns. Non-NULL return
 * flags a set() failure inside the thread. */
typedef struct {
    uintptr_t key;
    void *payload;
} worker_arg;

static void *worker_set_then_exit(void *p) {
    worker_arg *a = p;
    if (mjs_tls_set(a->key, a->payload) != 0)
        pthread_exit((void *)1);
    pthread_exit(0);
}

int main(void) {
    uintptr_t key_dt = 0;   /* key carrying counting_dtor */
    uintptr_t key_nul = 0;  /* key carrying no destructor */
    static int slot_a;
    static char slot_b[64];

    /* create: destructor form */
    int rc = mjs_tls_create(counting_dtor, &key_dt);
    CHECK(rc == 0, "create(destructor) returns 0");
    CHECK(key_dt != 0, "create(destructor) mints a nonzero key");

    /* create: NULL-destructor form */
    rc = mjs_tls_create(NULL, &key_nul);
    CHECK(rc == 0 && key_nul != 0, "create(NULL destructor) returns 0, nonzero key");
    CHECK(key_nul != key_dt, "two creates mint distinct keys");

    /* get: unset key is NULL (and allocates nothing) */
    CHECK(mjs_tls_get(key_dt) == NULL, "get(unset) == NULL");

    /* set/get round-trip + overwrite */
    rc = mjs_tls_set(key_dt, &slot_a);
    CHECK(rc == 0 && mjs_tls_get(key_dt) == &slot_a, "set/get round-trip");
    rc = mjs_tls_set(key_dt, slot_b);
    CHECK(rc == 0 && mjs_tls_get(key_dt) == slot_b, "overwrite set wins");
    CHECK(mjs_tls_get(key_nul) == NULL, "second key unaffected (isolation)");

    /* bad keys: never minted (ids start at 1), must be rejected safely */
    const uintptr_t bad = (uintptr_t)0 - 1;
    CHECK(mjs_tls_set(bad, &slot_a) == -EINVAL, "set(bad key) == -EINVAL");
    CHECK(mjs_tls_get(bad) == NULL, "get(bad key) == NULL");
    CHECK(mjs_tls_destroy(bad) == -EINVAL, "destroy(bad key) == -EINVAL");

    /* destroy semantics: valid once, then invalid/double */
    rc = mjs_tls_destroy(key_nul);
    CHECK(rc == 0, "destroy(valid) == 0");
    CHECK(mjs_tls_destroy(key_nul) == -EINVAL, "double destroy == -EINVAL");
    CHECK(mjs_tls_set(key_nul, &slot_a) == -EINVAL, "set(after destroy) == -EINVAL");
    CHECK(mjs_tls_get(key_nul) == NULL, "get(after destroy) == NULL");
    CHECK(mjs_tls_get(key_dt) == slot_b, "sibling key survives destroy");

    /* out_key untouched on failed create: exhaust the host pthread-key
     * pool. If this host has no reachable limit within the cap, skip. */
    enum { POOL_CAP = 8192 };
    static uintptr_t pool[POOL_CAP];
    size_t pooled = 0;
    int saw_failure = 0;
    const uintptr_t sentinel = (uintptr_t)&sentinel;
    while (pooled < POOL_CAP) {
        uintptr_t k = sentinel;
        rc = mjs_tls_create(NULL, &k);
        if (rc != 0) {
            saw_failure = 1;
            CHECK(k == sentinel, "out_key untouched on failed create");
            CHECK(rc < 0, "failed create reports negative errno");
            break;
        }
        pool[pooled++] = k;
    }
    if (!saw_failure)
        printf("  skip out_key-untouched (no exhaustion within %d creates)\n",
               POOL_CAP);
    for (size_t i = 0; i < pooled; i++)
        if (mjs_tls_destroy(pool[i]) != 0) {
            g_failures++;
            printf("  FAIL cleanup destroy pool[%zu]\n", i);
        }

    /* destructor-exactly-once at thread exit */
    atomic_store(&g_dtor_calls, 0);
    g_dtor_seen = 0;
    static char payload[32];
    memcpy(payload, "tls-dtor-payload", sizeof("tls-dtor-payload"));
    worker_arg wa = { key_dt, payload };
    pthread_t th;
    rc = pthread_create(&th, 0, worker_set_then_exit, &wa);
    CHECK(rc == 0, "pthread_create(worker)");
    void *retval = 0;
    rc = pthread_join(th, &retval);
    CHECK(rc == 0 && retval == 0, "worker set succeeded (join retval 0)");
    CHECK(atomic_load(&g_dtor_calls) == 1,
          "destructor fires EXACTLY ONCE at thread exit");
    CHECK(g_dtor_seen == payload, "destructor receives the stored value");

    printf("\n");
    if (g_failures != 0) {
        printf("RESULT: %d FAILED\n", g_failures);
        return 1;
    }
    printf("RESULT: all green\n");
    return 0;
}
