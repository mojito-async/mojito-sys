/*
 * tests/contract_sweep/sweep.h — shared "contract sweep" instrumentation
 * (issue mojito-async#170, fix item 1).
 *
 * PR #168 (issue #167) introduced this pattern locally, scoped to
 * io_uring: tests/s6/iouring_submit/iouring_submit_contract.c wraps every
 * mjs_iouring_* call it makes in an RC() macro that tallies how many
 * observed rc values were POSITIVE, because the frozen contract
 * (native/include/mojito_sys.h:23-25) is "0 == success; negative ==
 * -errno" and a positive rc is undecodable — SysError.from_rc reads it as
 * a fabricated POSIX errno (that is exactly how #167 reached users).
 * #170 asks to generalise that shape across every public entry point
 * ("a loop over a table") instead of leaving it a one-off.
 *
 * NOT every mjs_* entry point is in the 0-or-negative-errno family, and
 * pretending otherwise would be the same disease #170 is about, one level
 * down: a blanket, unverified claim ("no mjs_* ever returns positive")
 * standing in for the real, narrower one the header actually makes.
 * mjs_page_size, mjs_granularity, mjs_abi_version, mjs_cpu_logical,
 * mjs_thread_self_id, mjs_iouring_probe/available, and the atomic
 * wake_*_u32 pair are all DOCUMENTED to return a positive value on
 * success (informational sizes/ids/versions/counts/predicates). RC() is
 * for the rc<=0 contract family; COUNT() logs the rest for coverage
 * visibility without asserting a sign that was never promised.
 *
 * Single translation unit only (contract_sweep.c #includes this once).
 * NOT thread-safe: RC()/COUNT() touch plain (non-atomic) globals, so only
 * call them from the driver's main thread. The two rendezvous helper
 * threads contract_sweep.c spawns (to unblock a condvar wait / race an
 * atomic wait without a lost-wakeup) call the raw mjs_* functions
 * directly instead of through these macros, so the tally is never
 * written from two threads at once.
 */
#ifndef MOJITO_SYS_CONTRACT_SWEEP_H
#define MOJITO_SYS_CONTRACT_SWEEP_H

#include <stdio.h>

#define SWEEP_LOG_MAX 32

static int sweep_rc_calls;
static int sweep_rc_violations;
static char sweep_rc_log[SWEEP_LOG_MAX][128];

static int sweep_count_calls;

/* Every RC-family call observed goes through here. Violations are
 * recorded, not printed immediately, so the driver's normal output stays
 * in call order and the final tally reads as the one assertion it is. */
static int sweep_rc_check(const char *call, int rc)
{
    sweep_rc_calls++;
    if (rc > 0) {
        if (sweep_rc_violations < SWEEP_LOG_MAX)
            snprintf(sweep_rc_log[sweep_rc_violations],
                     sizeof sweep_rc_log[0], "%s returned %+d", call, rc);
        sweep_rc_violations++;
    }
    return rc;
}

/* Informational-only counter for the documented-positive family: exists
 * so the driver's final report can say how much of the ABI surface it
 * actually touched, without folding non-rc values into the sign check. */
static long sweep_count_check(const char *call, long v)
{
    sweep_count_calls++;
    (void)call;
    return v;
}

#define RC(call)    sweep_rc_check(#call, (call))
#define COUNT(call) sweep_count_check(#call, (long)(call))

#endif /* MOJITO_SYS_CONTRACT_SWEEP_H */
