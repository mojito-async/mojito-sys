/* mojito-sys S4.1 — monotonic clock (issue #63).
 *
 * Frozen-ABI entry points (native/include/mojito_sys.h, s4-time block):
 *   mjs_clock_now       — monotonic reading normalized to nanoseconds;
 *   mjs_clock_resolution— smallest reportable tick, in nanoseconds.
 *
 * Return contract: 0 == success; negative == -errno; out-params untouched
 * on failure (NULL out-slot => -EFAULT before anything else happens).
 *
 * Normalization lives INSIDE the C layer so every consumer sees plain
 * nanoseconds regardless of platform source:
 *   - Linux (and any POSIX with clock_gettime): CLOCK_MONOTONIC — the
 *     non-setting, non-jumping clock; scheduler-safe per spec §19.
 *     (CLOCK_MONOTONIC_RAW is deliberately NOT used here: it is not
 *     slew-corrected and its NTP-drift exposure buys nothing for deadline
 *     math; the conformance suite cross-checks against RAW only through a
 *     wide ratio band.)
 *   - macOS: mach_absolute_time() ticks scaled by the mach_timebase_info
 *     numer/denom ratio. The timebase query is cached behind pthread_once
 *     (spec §19: "conversion/calibration SHOULD avoid repeated expensive
 *     setup") — one calibration per process, then pure integer scaling.
 *
 * Scaling identity: t*(n/d) == (t/d)*n + ((t%d)*n)/d. The remainder term
 * is unconditionally safe: r < d implies r*n < d*n < 2^64 whenever n,d
 * fit in 32 bits. The quotient product q*n fits precisely when the final
 * result t*(n/d) is itself representable — the identity never overflows
 * an answer that fits uint64_t.
 *
 * Linux-portable: no Mach/pthread_once symbols are referenced unless the
 * __APPLE__ path is compiled; no -arch or platform-specific flags needed.
 */

#include <errno.h>
#include <stdint.h>
#include <time.h>

#ifdef __APPLE__
#include <mach/mach_time.h>
#include <pthread.h>
#endif

#ifdef __APPLE__
static pthread_once_t mjs_timebase_once = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t mjs_timebase;

/* One-shot timebase calibration. If the kernel query ever failed we fall
 * back to the 1/1 identity rather than dividing by zero below. */
static void mjs_timebase_init(void) {
    if (mach_timebase_info(&mjs_timebase) != KERN_SUCCESS ||
        mjs_timebase.denom == 0 || mjs_timebase.numer == 0) {
        mjs_timebase.numer = 1;
        mjs_timebase.denom = 1;
    }
}

static void mjs_timebase_calibrate(void) {
    pthread_once(&mjs_timebase_once, mjs_timebase_init);
}
#endif /* __APPLE__ */

int mjs_clock_now(uint64_t *out_ns) {
    if (out_ns == NULL) {
        return -EFAULT;
    }
#ifdef __APPLE__
    mjs_timebase_calibrate();
    uint64_t t = mach_absolute_time();
    uint64_t q = t / (uint64_t)mjs_timebase.denom;
    uint64_t r = t % (uint64_t)mjs_timebase.denom;
    *out_ns = q * (uint64_t)mjs_timebase.numer +
              (r * (uint64_t)mjs_timebase.numer) / (uint64_t)mjs_timebase.denom;
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return -(errno > 0 ? errno : EINVAL);
    }
    *out_ns = (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
#endif
    return 0;
}

int mjs_clock_resolution(uint64_t *out_res_ns) {
    if (out_res_ns == NULL) {
        return -EFAULT;
    }
#ifdef __APPLE__
    /* One tick of mach_absolute_time lasts numer/denom ns; report the
     * ceiling so the value is never a reported-as-zero resolution,
     * floored at 1 ns. */
    mjs_timebase_calibrate();
    uint64_t n = (uint64_t)mjs_timebase.numer;
    uint64_t d = (uint64_t)mjs_timebase.denom;
    uint64_t res = (n + d - 1) / d;
    *out_res_ns = res > 0 ? res : 1;
#else
    struct timespec ts;
    if (clock_getres(CLOCK_MONOTONIC, &ts) != 0) {
        return -(errno > 0 ? errno : EINVAL);
    }
    uint64_t res =
        (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
    *out_res_ns = res > 0 ? res : 1;
#endif
    return 0;
}
