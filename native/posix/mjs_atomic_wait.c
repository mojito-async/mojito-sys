/* mojito-sys S3.3 — atomic wait/wake on u32 words (issue #59, spec §18).
 *
 * Implements the mjs_atomic_* surface declared in
 * native/include/mojito_sys.h under the s3-atomic-wait block.
 *
 * Backend coverage: Linux futex (#59) via the FUTEX_WAIT_PRIVATE /
 * FUTEX_WAKE_PRIVATE fast (non-realtime, per-process) ops, and — since
 * #60 — a macOS fallback built from the SAME exported sync primitives
 * the rest of s3 ships (mjs_mutex_* + mjs_condvar_*): an address-keyed
 * waiter table of 256 hashed slots, each holding one NativeMutex and
 * one NativeCondVar guarding a FIFO list of stack-resident waiter
 * records. No __ulock / private kernel interface anywhere (spec §18);
 * nm on libmojito_sys.dylib shows zero new symbols from this file.
 * Windows WaitOnAddress/WakeByAddress* remains a later issue; hosts
 * with neither backend keep the documented -ENOSYS stub so callers and
 * the backend-parameterized suite (tests/s3/sync/atomic_wait/)
 * red-exclude cleanly instead of hanging.
 *
 * FALLBACK SEMANTICS PARITY vs futex (#60):
 *   - Lost-wakeup freedom: a waiter checks *addr == expected, links its
 *     record, and sleeps ALL while holding its slot mutex; a waker must
 *     hold that mutex to mark a matching record woken. So any wake is
 *     strictly ordered either before registration (the waiter's value
 *     re-check then sees the post-wake word -> EAGAIN-style .ok) or
 *     after (the flag is already set when the waiter resumes). Handoff
 *     is per-record (keyed by EXACT address), so waiters hashing onto
 *     the same physical slot can never steal each other's wakes.
 *   - Exact wake counts: wake_one/wake_all return the number of records
 *     they actually marked, 0 when none matched — same contract as the
 *     futex return value.
 *   - wake beats timeout: a timedwait expiry still checks its own woken
 *     flag first, mirroring the kernel's atomic value-check-before-
 *     ETIMEDOUT behavior.
 *   - Spurious .ok is permitted by the shared contract; broadcast (not
 *     signal) wakes the whole slot, so non-matching waiters re-sleep —
 *     thundering herd is accepted in exchange for exactness.
 *   - FIFO wake choice within an address, like the kernel's queue.
 *
 * TIME64 SAFETY (Linux path): the kernel timeout is never an absolute
 * deadline. The wait loop re-derives the REMAINING span against
 * mjs_clock_now (CLOCK_MONOTONIC under the hood) before each futex
 * attempt and passes that as a relative timespec. Remaining spans of
 * real schedulers are small, so tv_sec fits a 32-bit time_t on every
 * legacy kernel/arch — no futex_time64 dependency anywhere in this
 * file. The fallback path delegates the same absolute-deadline problem
 * to mjs_condvar_wait_until, which already carries the platform
 * mapping (condattr CLOCK_MONOTONIC / relative-NP).
 *
 * EINTR / spurious handling: a signal-interrupted wait (futex -EINTR)
 * or any other wake without a predicate guarantee simply re-enters the
 * loop: the value is atomically re-checked by the next FUTEX_WAIT
 * itself, which also closes the lost-wake race between "deadline
 * expired" and "word changed" (an expired deadline still goes through
 * the kernel's atomic value check with a zero-length timeout). The
 * fallback loop has the identical shape around its condvar.
 */
#include "mojito_sys.h"

#include <errno.h>

#if defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#endif

#if defined(__linux__)

/* One raw futex(2) syscall; ts == NULL means "no timeout". Private (same
 * process) op set only — spec §18 forbids private KERNEL interfaces, but
 * the _PRIVATE futex ops are stable public ABI since Linux 2.6.22. */
static long mjs_futex(uint32_t *uaddr, int op, uint32_t val,
                      const struct timespec *ts) {
    return syscall(SYS_futex, uaddr, op, val, ts, NULL, 0);
}

static int mjs_atomic_wait_linux(const uint32_t *addr, uint32_t expected,
                                 const uint64_t *deadline_ns) {
    for (;;) {
        struct timespec remaining;
        struct timespec *ts = NULL;
        if (deadline_ns != NULL) {
            uint64_t now = 0;
            if (mjs_clock_now(&now) != 0)
                return -EINVAL; /* clock failure: refuse to guess a span */
            uint64_t rem =
                (*deadline_ns <= now) ? 0 : (*deadline_ns - now);
            /* rem == 0 keeps the expiry race-safe: the kernel still
             * atomically checks the word first (EAGAIN -> ok) before
             * reporting ETIMEDOUT, so a change racing the deadline can
             * never be misreported as a timeout. */
            remaining.tv_sec = (time_t)(rem / 1000000000ULL);
            remaining.tv_nsec = (long)(rem % 1000000000ULL);
            ts = &remaining;
        }
        long rc = mjs_futex((uint32_t *)addr, FUTEX_WAIT_PRIVATE, expected, ts);
        if (rc == 0)
            return 0; /* woken by a wake_one/wake_all */
        int err = errno;
        if (err == EAGAIN)
            return 0; /* DOCUMENTED: word != expected at sleep time -> .ok */
        if (err == EINTR)
            continue; /* signal: re-check + re-arm the remaining span */
        if (err == ETIMEDOUT)
            return -ETIMEDOUT;
        return -err;
    }
}

#endif /* __linux__ */

#if defined(__APPLE__) && !defined(__linux__)

#include "mjs_sync_internal.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

/* ---- hashed waiter table (issue #60) -------------------------------------
 *
 * 256 slots, address-hashed; each slot owns one mjs_mutex + one
 * mjs_condvar and guards a FIFO list of waiter records that LIVE ON THE
 * WAITING THREAD'S STACK (no per-call allocation, SYS-4). Records are
 * keyed by the EXACT address, so waiters colliding into one physical
 * slot never steal each other's wakes; the slot lock only serializes
 * registration/waking. Composed entirely from the exported s3 C layer —
 * no new symbols, no __ulock, no private kernel interface.
 */

#define MJS_AW_SLOTS 256 /* power of two */

typedef struct aw_waiter {
    const uint32_t *addr;      /* exact key of this wait */
    int woken;                 /* set by a waker under the slot mutex  */
    int linked;                /* record currently in the slot list    */
    struct aw_waiter *next;
} aw_waiter;

typedef struct {
    mjs_mutex *mx;
    mjs_condvar *cv;
    aw_waiter *head;
    aw_waiter **tail; /* FIFO: append at tail, wake scans from head */
} aw_slot;

static aw_slot mjs_aw_slots[MJS_AW_SLOTS];
static pthread_once_t mjs_aw_once = PTHREAD_ONCE_INIT;
static int mjs_aw_init_rc; /* 0 once the table is usable */

static void mjs_aw_init(void) {
    for (int i = 0; i < MJS_AW_SLOTS; i++) {
        aw_slot *s = &mjs_aw_slots[i];
        int rc = mjs_mutex_init(&s->mx);
        if (rc != 0) {
            mjs_aw_init_rc = rc;
            return;
        }
        rc = mjs_condvar_init(&s->cv);
        if (rc != 0) {
            mjs_aw_init_rc = rc;
            return;
        }
        s->head = NULL;
        s->tail = &s->head;
    }
}

static aw_slot *mjs_aw_slot_for(const uint32_t *addr) {
    pthread_once(&mjs_aw_once, mjs_aw_init);
    uint64_t h = (uint64_t)(uintptr_t)addr >> 2;
    h *= UINT64_C(0x9E3779B97F4A7C15); /* golden-ratio spread */
    return &mjs_aw_slots[(h >> 32) & (MJS_AW_SLOTS - 1)];
}

static void mjs_aw_link(aw_slot *s, aw_waiter *w) {
    w->next = NULL;
    w->linked = 1;
    *s->tail = w;
    s->tail = &w->next;
}

static void mjs_aw_unlink(aw_slot *s, aw_waiter *me) {
    for (aw_waiter **pp = &s->head; *pp != NULL; pp = &(*pp)->next) {
        if (*pp == me) {
            *pp = me->next;
            if (s->tail == &me->next)
                s->tail = pp;
            me->linked = 0;
            return;
        }
    }
}

static int mjs_atomic_wait_fallback(const uint32_t *addr, uint32_t expected,
                                    const uint64_t *deadline_ns) {
    aw_slot *s = mjs_aw_slot_for(addr);
    int rc = mjs_mutex_lock(s->mx);
    if (rc != 0)
        return rc;
    aw_waiter me;
    for (;;) {
        if (*addr != expected) {
            mjs_mutex_unlock(s->mx);
            return 0; /* futex EAGAIN parity: word changed -> .ok */
        }
        me.addr = addr;
        me.woken = 0;
        mjs_aw_link(s, &me);
        /* Atomically release mx while parked (pthread semantics inside
         * the condvar layer); we hold it again on EVERY return. A waker
         * can only mark us between our link and this sleep or while we
         * are parked — both observed via me.woken below. */
        rc = (deadline_ns != NULL)
                 ? mjs_condvar_wait_until(s->cv, s->mx, *deadline_ns)
                 : mjs_condvar_wait(s->cv, s->mx);
        if (!me.woken)
            mjs_aw_unlink(s, &me); /* timeout / spurious / error path */
        if (me.woken) {
            mjs_mutex_unlock(s->mx);
            return 0; /* named handoff wins over an expiry, like futex */
        }
        if (rc != 0) {
            mjs_mutex_unlock(s->mx);
            return rc; /* -ETIMEDOUT status, or a real error verbatim */
        }
        /* Spurious broadcast wake with no handoff for OUR address:
         * loop, re-check the predicate, re-arm. */
    }
}

/* Shared wake engine: mark the first (wake_one) or every (wake_all)
 * record whose key matches addr exactly. Returns the exact number
 * marked — the same contract as the futex FUTEX_WAKE return value. */
static int mjs_atomic_wake_fallback(uint32_t *addr, int all) {
    aw_slot *s = mjs_aw_slot_for(addr);
    int rc = mjs_mutex_lock(s->mx);
    if (rc != 0)
        return rc;
    int n = 0;
    aw_waiter **pp = &s->head;
    while (*pp != NULL) {
        aw_waiter *w = *pp;
        if (w->addr != (const uint32_t *)addr) {
            pp = &w->next;
            continue;
        }
        ++n;
        *pp = w->next; /* unlink; the waiter reads woken after re-acquire */
        if (s->tail == &w->next)
            s->tail = pp;
        w->linked = 0;
        w->next = NULL;
        w->woken = 1;
        if (!all)
            break; /* FIFO first match only */
    }
    if (n > 0)
        mjs_condvar_broadcast(s->cv); /* whole slot: non-matching waiters
                                         re-sleep on their predicate */
    mjs_mutex_unlock(s->mx);
    return n;
}

#endif /* __APPLE__ && !__linux__ */

int mjs_atomic_wait_on_u32(const uint32_t *addr, uint32_t expected,
                           const uint64_t *deadline_ns) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    return mjs_atomic_wait_linux(addr, expected, deadline_ns);
#elif defined(__APPLE__)
    mjs_aw_slot_for(addr); /* force one-time table init */
    if (mjs_aw_init_rc != 0)
        return mjs_aw_init_rc; /* init failed once: deterministic rc */
    return mjs_atomic_wait_fallback(addr, expected, deadline_ns);
#else
    (void)expected; /* documented stub: no backend on this host yet */
    (void)deadline_ns;
    return -ENOSYS;
#endif
}

int mjs_atomic_wake_one_u32(uint32_t *addr) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    long rc = mjs_futex(addr, FUTEX_WAKE_PRIVATE, 1, NULL);
    return rc >= 0 ? (int)rc : -errno;
#elif defined(__APPLE__)
    mjs_aw_slot_for(addr); /* force one-time table init */
    if (mjs_aw_init_rc != 0)
        return mjs_aw_init_rc;
    return mjs_atomic_wake_fallback(addr, 0);
#else
    (void)addr;
    return -ENOSYS; /* no backend on this host */
#endif
}

int mjs_atomic_wake_all_u32(uint32_t *addr) {
    if (addr == NULL)
        return -EFAULT;
#if defined(__linux__)
    /* INT_MAX waiter cap: every current waiter, exactly the wake_all
     * semantic; no practical queue can hold more. */
    long rc = mjs_futex(addr, FUTEX_WAKE_PRIVATE, 0x7fffffff, NULL);
    return rc >= 0 ? (int)rc : -errno;
#elif defined(__APPLE__)
    mjs_aw_slot_for(addr); /* force one-time table init */
    if (mjs_aw_init_rc != 0)
        return mjs_aw_init_rc;
    return mjs_atomic_wake_fallback(addr, 1);
#else
    (void)addr;
    return -ENOSYS; /* no backend on this host */
#endif
}
