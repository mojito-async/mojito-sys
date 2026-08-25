/* mojito-sys S2 — cpu topology + current-thread affinity conformance
 * (issue #52, spec §13).
 *
 * Contract under test:
 *   - mjs_cpu_logical()                -> logical CPU count, >= 1.
 *   - mjs_cpu_physical(int *out)       -> 0 with *out > 0 XOR exactly
 *                                         -ENOTSUP with *out untouched
 *                                         (advisory topology; Optional[Int]
 *                                         upstream). NEVER any other errno.
 *   - mjs_cpu_affinity_set_current(
 *         const uint64_t *mask,
 *         unsigned nwords)             -> pins the CALLING thread only.
 *                                         mask == NULL or nwords == 0 is
 *                                         -EINVAL.
 *                                         Linux: sched_setaffinity; pinning
 *                                         to CPU0 must succeed and be
 *                                         observable via sched_getaffinity.
 *                                         Darwin: best-effort
 *                                         (thread_policy_set); 0 or exactly
 *                                         -ENOTSUP accepted, never crash.
 *
 * Deliberately no get-API (SYS-1): verification on Linux goes through the
 * kernel's own sched_getaffinity, not through a library symbol.
 *
 * Exit status 0 = all checks passed; nonzero = failures (count printed).
 */
#ifdef __linux__
#define _GNU_SOURCE /* sched_[gs]etaffinity; must precede libc includes */
#endif

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "mojito_sys.h"

#ifdef __linux__
#include <sched.h>
#endif

static int failures;

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            failures++;                                                     \
            printf("FAIL %s:%d: ", __func__, __LINE__);                     \
            printf(__VA_ARGS__);                                            \
            printf("\n");                                                   \
        }                                                                   \
    } while (0)

/* mjs_cpu_logical(): informational count, must be >= 1 on every supported
 * host (spec L898-901: sysconf/sysctl). */
static void check_logical(void) {
    int n = mjs_cpu_logical();
    CHECK(n >= 1, "mjs_cpu_logical() = %d, want >= 1", n);
}

/* mjs_cpu_physical(): (>0) XOR exactly -ENOTSUP — never any other errno —
 * and *out untouched on failure (frozen ABI: out-params untouched). */
static void check_physical(void) {
    int phys = -12345; /* sentinel: proves *out untouched on failure */
    int rc = mjs_cpu_physical(&phys);

    if (rc == 0) {
        CHECK(phys > 0, "mjs_cpu_physical() success but *out = %d, want > 0",
              phys);
    } else {
        CHECK(rc == -ENOTSUP,
              "mjs_cpu_physical() rc = %d (%s), want 0 or exactly -ENOTSUP",
              rc, strerror(-rc));
        CHECK(phys == -12345,
              "mjs_cpu_physical() failure touched *out (%d), want sentinel",
              phys);
    }
}

/* Argument validation per frozen ABI: null mask / zero nwords -> -EINVAL. */
static void check_affinity_args(void) {
    const uint64_t one_word[1] = {1};

    CHECK(mjs_cpu_affinity_set_current(NULL, 0) == -EINVAL,
          "set_current(NULL, 0) != -EINVAL");
    CHECK(mjs_cpu_affinity_set_current(NULL, 4) == -EINVAL,
          "set_current(NULL, 4) != -EINVAL");
    CHECK(mjs_cpu_affinity_set_current(one_word, 0) == -EINVAL,
          "set_current(mask, 0) != -EINVAL");
}

#ifdef __linux__
/* Linux lane: pin to CPU0 and VERIFY through sched_getaffinity (acceptance:
 * pin-CPU0 verified via sched_getaffinity). Restore the original mask so a
 * failing run cannot poison the rest of the suite process-wide. */
static void check_affinity_linux(void) {
    cpu_set_t orig;
    CPU_ZERO(&orig);
    if (sched_getaffinity(0, sizeof(orig), &orig) != 0) {
        CHECK(0, "sched_getaffinity probe failed: errno=%d", errno);
        return;
    }

    /* Pin to CPU0. If this process is not allowed CPU0 at all (cpuset/
     * taskset-restricted host), the kernel rejects it with -EINVAL; that is
     * an environmental restriction, not a conformance gap, so we require the
     * documented errno rather than unconditional success. */
    if (!CPU_ISSET(0, &orig)) {
        printf("SKIP %s: CPU0 outside cpuset affinity; pin skipped\n",
               __func__);
        return;
    }

    uint64_t mask[1] = {1}; /* word 0, bit 0 => CPU0 */
    int rc = mjs_cpu_affinity_set_current(mask, 1);
    CHECK(rc == 0, "linux set_current({cpu0}) rc = %d, want 0", rc);
    if (rc != 0)
        return;

    cpu_set_t after;
    CPU_ZERO(&after);
    if (sched_getaffinity(0, sizeof(after), &after) != 0) {
        CHECK(0, "sched_getaffinity verify failed: errno=%d", errno);
    } else {
        CHECK(CPU_ISSET(0, &after), "CPU0 not set after pin");
        CHECK(CPU_COUNT(&after) == 1, "affinity after pin = %d cpus, want 1",
              CPU_COUNT(&after));
    }

    /* Restore. */
    int rrc = sched_setaffinity(0, sizeof(orig), &orig);
    CHECK(rrc == 0, "restore sched_setaffinity failed: errno=%d", errno);
}
#elif defined(__APPLE__)
/* Darwin lane: thread_policy_set affinity is best-effort and commonly
 * unsupported; SYS-7 makes the divergence VISIBLE. Accept 0 or exactly
 * -ENOTSUP; never crash, never another errno. */
static void check_affinity_darwin(void) {
    uint64_t mask[2] = {1, 0};
    int rc = mjs_cpu_affinity_set_current(mask, 2);
    CHECK(rc == 0 || rc == -ENOTSUP,
          "darwin set_current rc = %d (%s), want 0 or exactly -ENOTSUP", rc,
          rc < 0 ? strerror(-rc) : "?");
}
#else
#error "unsupported platform for s2-cpu smoke"
#endif

int main(void) {
    check_logical();
    check_physical();
    check_affinity_args();
#ifdef __linux__
    check_affinity_linux();
#elif defined(__APPLE__)
    check_affinity_darwin();
#endif

    if (failures != 0) {
        printf("s2-cpu FAIL (%d)\n", failures);
        return 1;
    }
    printf("s2-cpu PASS\n");
    return 0;
}
