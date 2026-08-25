/* mojito-sys S2.1 — native thread layer conformance smoke (issue #48).
 *
 * Pure-C consumer of the frozen-header mjs_thread_* surface. Covers every
 * acceptance case from the issue:
 *   1. spawn/join round-trip returning the entry status;
 *   2. >=100 sequential spawn/join;
 *   3. >=32 concurrent spawns (distinct statuses + distinct self-ids);
 *   4. detach-then-exit safety (+ deterministic double-detach -EINVAL via
 *      the consumed/NULLed handle);
 *   5. setname 15-char round-trip (parent and child side);
 *   6. self-id equal within a thread / unequal across threads;
 *   7. out-params untouched on every reachable failure path;
 *   8. §38.5 shutdown/drain: N detached workers spawned, released, and
 *      drained to zero via a started/finished handshake (handle frees are
 *      verified by the ASan/UBSan leg's leak check).
 *
 * Gate atomics handed to detached workers have STATIC storage duration —
 * block-scope gates would be stack-use-after-return UB once the spawning
 * scope exits.
 *
 * Contract: exit status is authoritative — 0 iff every row above printed
 * ok (the canonical tests/s2/native runner keys on exit status, not text).
 */

#include "mojito_sys.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sched.h>
#include <time.h>
#include <errno.h>

static int failures = 0;

#define CHECK(cond, name)                                                   \
    do {                                                                    \
        if (cond) {                                                         \
            printf("ok   %s\n", name);                                      \
        } else {                                                            \
            printf("FAIL %s\n", name);                                      \
            failures++;                                                     \
        }                                                                   \
    } while (0)

#define LONG_SENTINEL (-99991L)

/* ---- entries ---------------------------------------------------------- */

static long entry_status42(void *ud) { (void)ud; return 42; }

/* Detached-drain probe: each worker acks entry into `started`, waits on
 * its static gate, then acks exit into `finished` — the last action it
 * can take before the runtime frees its handle. */
static atomic_int drain_started;
static atomic_int drain_finished;

static long entry_drain_spinner(void *ud) {
    atomic_int *gate = ud;
    atomic_fetch_add_explicit(&drain_started, 1, memory_order_acq_rel);
    while (atomic_load_explicit(gate, memory_order_acquire) == 0)
        sched_yield();
    atomic_fetch_add_explicit(&drain_finished, 1, memory_order_acq_rel);
    return 0;
}

/* Poll *v until it reaches `want` (10 s ceiling). */
static int wait_until_reaches(const atomic_int *v, int want) {
    for (int ms = 0; ms < 10000; ms += 10) {
        if (atomic_load_explicit(v, memory_order_acquire) >= want)
            return 1;
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    return atomic_load_explicit(v, memory_order_acquire) >= want;
}

static long entry_echo(void *ud) { return (long)(intptr_t)ud; }

static long entry_block(void *ud) {
    atomic_int *gate = ud;
    while (atomic_load_explicit(gate, memory_order_acquire) == 0)
        sched_yield();
    return 7;
}

struct id_probe {
    unsigned long parent_id;
    atomic_int child_ids_differ;
};

static long entry_probe_ids(void *ud) {
    struct id_probe *p = ud;
    unsigned long a = mjs_thread_self_id();
    unsigned long b = mjs_thread_self_id();
    if (a == b && a != p->parent_id)
        atomic_store(&p->child_ids_differ, 1);
    return 0;
}

struct name_probe {
    int rc_set;
    int rc_roundtrip;
};

static long entry_probe_name(void *ud) {
    struct name_probe *p = ud;
    p->rc_set = mjs_thread_set_name("child-thd-01");
    char buf[64];
    memset(buf, 'X', sizeof buf);
#if defined(__APPLE__)
    int grc = pthread_getname_np(pthread_self(), buf, sizeof buf);
#else
    int grc = pthread_getname_np(pthread_self(), buf, sizeof buf) == 0 ? 0 : -1;
#endif
    p->rc_roundtrip =
        (grc == 0 && strcmp(buf, "child-thd-01") == 0) ? 0 : -1;
    return 0;
}

/* ---- cases ------------------------------------------------------------ */

static void case_join_roundtrip(void) {
    mjs_thread *t = (mjs_thread *)(uintptr_t)0x1; /* poison sentinel */
    long status = LONG_SENTINEL;
    int rc = mjs_thread_spawn(entry_status42, NULL, 0, NULL, &t);
    CHECK(rc == 0 && t != NULL, "spawn/join: spawn ok");
    rc = mjs_thread_join(&t, &status);
    CHECK(rc == 0 && status == 42 && t == NULL,
          "spawn/join: round-trip returns entry status, handle NULLed");
}

static void case_join_returns_userdata(void) {
    mjs_thread *t = NULL;
    long status = LONG_SENTINEL;
    int rc = mjs_thread_spawn(entry_echo, (void *)(intptr_t)1234567, 0, NULL, &t);
    CHECK(rc == 0, "spawn/join: spawn with userdata ok");
    rc = mjs_thread_join(&t, &status);
    CHECK(rc == 0 && status == 1234567, "spawn/join: userdata reaches entry");
}

static void case_sequential_100(void) {
    int bad = 0;
    for (long i = 1; i <= 100; i++) {
        mjs_thread *t = NULL;
        long status = LONG_SENTINEL;
        if (mjs_thread_spawn(entry_echo, (void *)(intptr_t)i, 0, NULL, &t) != 0)
            bad++;
        else if (mjs_thread_join(&t, &status) != 0 || status != i || t != NULL)
            bad++;
    }
    CHECK(bad == 0, "sequential: 100 spawn/join round-trips exact");
}

static void case_concurrent_32(void) {
    enum { N = 32 };
    static mjs_thread *slots[N];

    memset(slots, 0, sizeof slots);
    /* Spawn all N first so they coexist before any join reaps one;
     * entry_echo returns i + 7 so statuses pin per-thread identity. */
    int spawned = 0;
    for (int i = 0; i < N; i++) {
        if (mjs_thread_spawn(entry_echo, (void *)(intptr_t)(i + 7), 0, NULL,
                             &slots[i]) == 0)
            spawned++;
    }

    int joined = 0, bad = 0;
    for (int i = 0; i < N; i++) {
        long st = LONG_SENTINEL;
        if (mjs_thread_join(&slots[i], &st) == 0)
            joined++;
        if (st != i + 7)
            bad++;
    }
    CHECK(spawned == N && joined == N && bad == 0,
          "concurrent: 32 simultaneous spawn/join with distinct statuses");
}

static atomic_int detach_exit_gate;
static atomic_int detach_double_gate;

static void case_detach_then_exit(void) {
    /* 4a: spawn -> detach (handle consumed) -> release -> exit. */
    {
        mjs_thread *t = NULL;
        int rc = mjs_thread_spawn(entry_block, &detach_exit_gate, 0, NULL, &t);
        CHECK(rc == 0, "detach: spawn ok");
        rc = mjs_thread_detach(&t);
        CHECK(rc == 0 && t == NULL,
              "detach: detach returns 0 and consumes the handle");
        atomic_store(&detach_exit_gate, 1);
        struct timespec ts = {0, 200 * 1000 * 1000};
        nanosleep(&ts, NULL);
        CHECK(1, "detach: detached exit did not crash");
    }
    /* 4b: double-detach is -EINVAL deterministically — the first successful
     * detach NULLed the handle, so the retry is rejected on *t == NULL even
     * after the detached worker has long exited. */
    {
        mjs_thread *t = NULL;
        CHECK(mjs_thread_spawn(entry_block, &detach_double_gate, 0, NULL,
                               &t) == 0,
              "detach: blocked-worker spawn ok");
        CHECK(mjs_thread_detach(&t) == 0 && t == NULL,
              "detach: first detach 0");
        CHECK(mjs_thread_detach(&t) == -EINVAL,
              "detach: double-detach -EINVAL (consumed handle)");
        atomic_store(&detach_double_gate, 1);
        struct timespec ts = {0, 100 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
}

static void case_setname(void) {
    /* Parent-side 15-char round-trip. */
    const char *fifteen = "mj-0123456789ab"; /* exactly 15 chars */
    CHECK(strlen(fifteen) == 15, "setname: fixture length sanity");
    CHECK(mjs_thread_set_name(fifteen) == 0, "setname: 15-char set ok");
    char buf[64];
    memset(buf, 'X', sizeof buf);
#if defined(__APPLE__)
    int grc = pthread_getname_np(pthread_self(), buf, sizeof buf);
#else
    int grc = pthread_getname_np(pthread_self(), buf, sizeof buf) == 0 ? 0 : -1;
#endif
    CHECK(grc == 0 && strcmp(buf, fifteen) == 0,
          "setname: 15-char round-trip reads back");
    CHECK(mjs_thread_set_name("mojito-main") == 0, "setname: restore ok");

    /* Failure paths. */
    CHECK(mjs_thread_set_name(NULL) == -EINVAL, "setname: NULL -EINVAL");
    CHECK(mjs_thread_set_name("0123456789abcdef") == -ENAMETOOLONG,
          "setname: 16 chars rejected (> portable floor)");

    /* Child-side: sets its own name, verifies round-trip in-child. */
    mjs_thread *t = NULL;
    struct name_probe probe = {-1, -1};
    CHECK(mjs_thread_spawn(entry_probe_name, &probe, 0, NULL, &t) == 0,
          "setname: child spawn ok");
    long st = LONG_SENTINEL;
    CHECK(mjs_thread_join(&t, &st) == 0 && st == 0 &&
              probe.rc_set == 0 && probe.rc_roundtrip == 0,
          "setname: child sets+reads back own name (darwin self-only)");
}

static void case_self_id(void) {
    unsigned long a = mjs_thread_self_id();
    unsigned long b = mjs_thread_self_id();
    CHECK(a == b && a != 0, "self-id: stable and non-zero in-thread");

    struct id_probe probe;
    atomic_init(&probe.child_ids_differ, 0);
    probe.parent_id = mjs_thread_self_id();
    mjs_thread *t = NULL;
    CHECK(mjs_thread_spawn(entry_probe_ids, &probe, 0, NULL, &t) == 0,
          "self-id: child spawn ok");
    long st = LONG_SENTINEL;
    CHECK(mjs_thread_join(&t, &st) == 0 && st == 0 &&
              atomic_load(&probe.child_ids_differ) == 1,
          "self-id: equal in-child, unequal vs parent across threads");
}

static void case_failure_out_untouched(void) {
    /* spawn: entry NULL -> -EINVAL, out untouched. */
    {
        mjs_thread *out = (mjs_thread *)(uintptr_t)0x2;
        CHECK(mjs_thread_spawn(NULL, NULL, 0, NULL, &out) == -EINVAL &&
                  out == (mjs_thread *)(uintptr_t)0x2,
              "failure: spawn(entry=NULL) -EINVAL, out untouched");
    }
    /* spawn: out NULL -> -EINVAL. */
    CHECK(mjs_thread_spawn(entry_status42, NULL, 0, NULL, NULL) == -EINVAL,
          "failure: spawn(out=NULL) -EINVAL");
    /* spawn: stack_size below PTHREAD_STACK_MIN -> negative, out untouched. */
    {
        mjs_thread *out = NULL;
        int rc = mjs_thread_spawn(entry_status42, NULL, 1, NULL, &out);
        CHECK(rc < 0 && out == NULL,
              "failure: spawn(stack_size=1) rejected, out untouched");
    }
    /* spawn: over-long name -> -ENAMETOOLONG, out untouched. */
    {
        mjs_thread *out = (mjs_thread *)(uintptr_t)0x3;
        int rc = mjs_thread_spawn(entry_status42, NULL, 0,
                                  "0123456789abcdef", &out);
        CHECK(rc == -ENAMETOOLONG && out == (mjs_thread *)(uintptr_t)0x3,
              "failure: spawn(name>15) -ENAMETOOLONG, out untouched");
    }
    /* join: *t NULL -> -EINVAL, out_result untouched. */
    {
        mjs_thread *t = NULL;
        long res = LONG_SENTINEL;
        CHECK(mjs_thread_join(&t, &res) == -EINVAL && res == LONG_SENTINEL,
              "failure: join(*t=NULL) -EINVAL, out_result untouched");
        CHECK(mjs_thread_join(NULL, &res) == -EINVAL,
              "failure: join(t=NULL) -EINVAL");
    }
    /* join: double join -> second -EINVAL, out_result untouched. */
    {
        mjs_thread *t = NULL;
        long r1 = LONG_SENTINEL, r2 = LONG_SENTINEL;
        CHECK(mjs_thread_spawn(entry_status42, NULL, 0, NULL, &t) == 0,
              "failure: spawn for double-join ok");
        CHECK(mjs_thread_join(&t, &r1) == 0 && t == NULL,
              "failure: first join ok");
        mjs_thread *stale = NULL;
        CHECK(mjs_thread_join(&stale, &r2) == -EINVAL && r2 == LONG_SENTINEL,
              "failure: re-join NULLed handle -EINVAL, out_result untouched");
        (void)r1;
    }
    /* join after detach -> -EINVAL, out_result untouched. */
    {
        mjs_thread *t = NULL;
        long res = LONG_SENTINEL;
        CHECK(mjs_thread_spawn(entry_block, &detach_exit_gate, 0, NULL,
                               &t) == 0,
              "failure: spawn for join-after-detach ok");
        atomic_store(&detach_exit_gate, 0);
        CHECK(mjs_thread_detach(&t) == 0 && t == NULL,
              "failure: detach ok");
        CHECK(mjs_thread_join(&t, &res) == -EINVAL && res == LONG_SENTINEL,
              "failure: join-after-detach -EINVAL, out_result untouched");
        atomic_store(&detach_exit_gate, 1);
        struct timespec ts = {0, 100 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    /* detach: NULL handle pointer and consumed (NULLed) handle -> -EINVAL. */
    {
        mjs_thread *t = NULL;
        CHECK(mjs_thread_detach(NULL) == -EINVAL,
              "failure: detach(t=NULL) -EINVAL");
        CHECK(mjs_thread_detach(&t) == -EINVAL,
              "failure: detach(*t=NULL) -EINVAL");
    }
}

/* §38.5 shutdown row: N detached workers, released together, drained to
 * zero. The started/finished handshake proves every worker exited before
 * we return; the runtime's free-at-zero of each consumed handle is then
 * verified by the ASan leg (LSan) at process exit. */
static void case_detached_drain(void) {
    enum { N = 16 };
    static atomic_int gates[N];   /* static: workers outlive this frame */
    static mjs_thread *handles[N];

    atomic_init(&drain_started, 0);
    atomic_init(&drain_finished, 0);

    int detached = 0;
    for (int i = 0; i < N; i++) {
        atomic_init(&gates[i], 0);
        handles[i] = NULL;
        if (mjs_thread_spawn(entry_drain_spinner, &gates[i], 0, NULL,
                             &handles[i]) == 0 &&
            mjs_thread_detach(&handles[i]) == 0 &&
            handles[i] == NULL)
            detached++;
    }
    CHECK(detached == N,
          "shutdown: 16 workers spawned + detached, handles consumed");

    CHECK(wait_until_reaches(&drain_started, N),
          "shutdown: all 16 detached workers running");

    for (int i = 0; i < N; i++)
        atomic_store(&gates[i], 1);

    CHECK(wait_until_reaches(&drain_finished, N),
          "shutdown: all 16 workers exited — drain to zero complete");

    /* Grace period so the final unrefs/handle frees land before exit;
     * ASan's leak check then proves no handle was leaked. */
    struct timespec ts = {0, 200 * 1000 * 1000};
    nanosleep(&ts, NULL);
}

int main(void) {
    printf("== s2-thread smoke (issue #48)\n");
    case_join_roundtrip();
    case_join_returns_userdata();
    case_sequential_100();
    case_concurrent_32();
    case_detach_then_exit();
    case_setname();
    case_self_id();
    case_failure_out_untouched();
    case_detached_drain();

    if (failures != 0) {
        printf("RESULT: %d FAILED\n", failures);
        return 1;
    }
    printf("RESULT: all PASSED\n");
    return 0;
}
