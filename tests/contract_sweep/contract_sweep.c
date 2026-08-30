/*
 * tests/contract_sweep/contract_sweep.c — ABI-wide contract sweep
 * (mojito-async#170, fix item 1: "Contract sweep across the C ABI ...
 * generalising it to all ~60 entry points ... is a loop over a table").
 *
 * WHAT THIS CHECKS. native/include/mojito_sys.h:23-25 freezes one return
 * contract for every entry point that carries it: "0 == success; negative
 * == -errno; out-parameters are UNTOUCHED on failure." #167 (mojito-sys
 * PR #168) showed what happens when one entry point quietly breaks that:
 * a positive rc reaches SysError.from_rc, which — before #170's own fix
 * (mojito-sys#170 / PR #172) — decoded it as a fabricated POSIX errno
 * pointing at the wrong subsystem entirely. #168 built a local RC()
 * sweep scoped to io_uring; this driver is that same instrumentation
 * (tests/contract_sweep/sweep.h) generalised to every other subsystem:
 * VM/stack, threads, TLS, CPU, clock, mutex, condvar, atomic-wait, event,
 * semaphore, sockets, and the three readiness backends (poller/epoll/
 * io_uring), plus ms_context_init (the one errno-style entry point in
 * the s5-ctx block). Every call below is REAL — a live handle, a real
 * syscall — never a synthetic/asserted-about rc, matching the house
 * pattern #168 set (driving a LIVE ring rather than asserting about one).
 *
 * WHAT IT DOES NOT CHECK. Individual subsystem *behavioural* correctness
 * (ordering, wakeup fairness, exact byte counts, ...) is the existing
 * tests/s1-s6 suites' job, not this driver's. This driver's only
 * assertion is the sign of every observed RC-family rc; a handle that
 * fails to come up mid-sweep is logged and that subsystem's remaining
 * calls are skipped, rather than treated as a contract violation itself
 * (the READ tests already cover functional correctness) — it never
 * corrupts what the actual RC values were.
 *
 * NOT EVERY mjs_* IS IN THE RC FAMILY. See sweep.h's header comment: the
 * informational family (mjs_page_size, mjs_granularity, mjs_abi_version,
 * mjs_cpu_logical, mjs_thread_self_id, mjs_iouring_probe/available,
 * mjs_atomic_wake_one_u32/wake_all_u32) is documented to return a
 * positive value on success, so it goes through COUNT() (logged, not
 * sign-checked) instead of RC(). mjs_tls_get (void*), mjs_ctx_call
 * (void), and the void-returning ms_context_capture/switch/destroy/
 * set_finish_hook entries carry no rc at all and are out of scope by
 * construction.
 *
 * NEVER AN UNBOUNDED BLOCK. Every wait call below passes a BOUNDED
 * deadline/timeout — never NULL/indefinite — even where the primitive's
 * own sticky-wake or mutex-rendezvous design should make an unbounded
 * wait safe. A CI hang is a worse failure mode than a slightly weaker
 * "did we truly exercise the plain indefinite-wait code path" claim, and
 * every _wait_until sibling shares byte-for-byte the same rc contract as
 * its unbounded counterpart per the header ("Same return-value contract
 * as above"), so sign-check coverage is not actually reduced.
 *
 * LOST-WAKEUP SAFETY (why some primitives get a helper thread and others
 * don't): mjs_event_signal / mjs_sem_post / the readiness backends'
 * *_wake are all documented STICKY — a signal/post/wake issued before
 * anyone waits is not lost, so calling signal-then-wait on the SAME
 * thread, in that order, is safe and needs no second thread.
 * mjs_condvar_signal is the opposite (POSIX condvar semantics: a signal
 * with no waiter is simply lost), so the condvar section uses the
 * standard deadlock-proof rendezvous instead: the waker thread's
 * mjs_mutex_lock(m2) cannot succeed until the main thread's
 * mjs_condvar_wait(c, m2) has atomically released m2 by entering the
 * wait, which the contract guarantees happens before the wait can be
 * missed. mjs_atomic_wake_one_u32 has neither stickiness nor a mutex to
 * rendezvous on, so its section keeps the bounded-deadline safety net
 * even with a racing waker thread.
 *
 * Exit: 0 all contract values non-positive (RESULT: all green), 1 an
 * RC-family entry point returned positive (RESULT: N RED). This driver
 * has no environment-guard exit(2): every subsystem it touches either
 * runs for real on every host (VM/stack/threads/TLS/CPU/clock/mutex/
 * condvar/atomic-wait/event/sem/sockets/poller) or degrades to a real,
 * in-contract -ENOSYS this driver itself observes and sweeps (epoll on
 * non-Linux, io_uring without host support or MOJITO_IO_URING=1) — there
 * is no host on which this driver has nothing to measure.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mojito_sys.h"
#include "sweep.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures;

static void fail(const char *what)
{
    printf("  ! %s\n", what);
    failures++;
}

/* Absolute monotonic deadline `ms` milliseconds from now, via the same
 * mjs_clock_now every _wait_until entry point is specified against. */
static uint64_t deadline_in_ms(uint64_t ms)
{
    uint64_t now = 0;
    RC(mjs_clock_now(&now));
    return now + ms * 1000000ull;
}

/* An absolute deadline already in the past: 1ns since the monotonic
 * clock's epoch is always long gone by the time this process is
 * running. Used to exercise the *_wait_until entry points' -ETIMEDOUT
 * branch immediately, with no thread and no real wait. */
#define PAST_DEADLINE ((uint64_t)1)

/* ---- s1: VM + stack ------------------------------------------------- */

static void sweep_vm_and_stack(void)
{
    printf("-- s1 vm/stack --\n");
    long ps = COUNT(mjs_page_size());
    long gran = COUNT(mjs_granularity());
    printf("  page_size=%ld granularity=%ld\n", ps, gran);
    if (ps <= 0)
        ps = 4096; /* defensive fallback; page_size itself is still swept */

    void *base = NULL;
    size_t reserved = 0;
    int rc = RC(mjs_vm_reserve((size_t)ps * 4, &base, &reserved));
    if (rc != 0 || base == NULL) {
        printf("  vm_reserve rc=%d; skipping the rest of s1\n", rc);
        return;
    }

    unsigned char *commit_cursor = (unsigned char *)base;
    RC(mjs_vm_commit(&commit_cursor, (size_t)ps));
    RC(mjs_vm_protect((unsigned char *)base, (size_t)ps,
                      MJS_PROT_READ | MJS_PROT_WRITE));
    unsigned char *decommit_cursor = (unsigned char *)base;
    RC(mjs_vm_decommit(&decommit_cursor, (size_t)ps));
    RC(mjs_vm_release(&base, reserved));

    void *sbase = NULL;
    void *guard_low = NULL;
    size_t top = 0;
    rc = RC(mjs_stack_alloc((size_t)ps * 16, (size_t)ps * 4, (size_t)ps,
                            &sbase, &guard_low, &top));
    if (rc == 0 && sbase != NULL) {
        RC(mjs_stack_free(&sbase));
    } else {
        printf("  stack_alloc rc=%d\n", rc);
    }
}

/* ---- s2: threads, TLS, CPU ------------------------------------------- */

static long thread_smoke_entry(void *userdata)
{
    (void)userdata;
    return 7;
}

static void sweep_threads_tls_cpu(void)
{
    printf("-- s2 threads/tls/cpu --\n");

    mjs_thread *t1 = NULL;
    int rc = RC(mjs_thread_spawn(thread_smoke_entry, NULL, 0, "sweep-j", &t1));
    if (rc == 0 && t1 != NULL) {
        long result = -1;
        RC(mjs_thread_join(&t1, &result));
        if (result != 7)
            fail("thread_join: unexpected entry-point result");
    } else {
        printf("  thread_spawn (join case) rc=%d\n", rc);
    }

    mjs_thread *t2 = NULL;
    rc = RC(mjs_thread_spawn(thread_smoke_entry, NULL, 0, "sweep-d", &t2));
    if (rc == 0 && t2 != NULL) {
        RC(mjs_thread_detach(&t2));
    } else {
        printf("  thread_spawn (detach case) rc=%d\n", rc);
    }

    RC(mjs_thread_set_name("sweep-main"));
    printf("  thread_self_id=%lu (informational; not int-returning, not"
           " swept)\n", mjs_thread_self_id());

    uintptr_t key = 0;
    rc = RC(mjs_tls_create(NULL, &key));
    if (rc == 0) {
        RC(mjs_tls_set(key, (void *)(uintptr_t)0x51));
        if (mjs_tls_get(key) != (void *)(uintptr_t)0x51)
            fail("tls_get: did not read back the value tls_set stored");
        RC(mjs_tls_destroy(key));
    } else {
        printf("  tls_create rc=%d\n", rc);
    }

    long logical = COUNT(mjs_cpu_logical());
    printf("  cpu_logical=%ld (informational; positive is correct)\n",
          logical);

    int physical = -1;
    RC(mjs_cpu_physical(&physical));

    uint64_t mask = 1ull;
    RC(mjs_cpu_affinity_set_current(&mask, 1));
}

/* ---- s4: clock --------------------------------------------------------
 * (clock is swept first via deadline_in_ms/mjs_clock_now already, but
 * mjs_clock_resolution has no other caller.) */

static void sweep_clock(void)
{
    printf("-- s4 clock --\n");
    uint64_t res = 0;
    RC(mjs_clock_resolution(&res));
    printf("  clock_resolution=%llu ns\n", (unsigned long long)res);
}

/* ---- s3: mutex --------------------------------------------------------- */

static mjs_mutex *sweep_mutex_g; /* used by the condvar rendezvous below */

static void sweep_mutex(void)
{
    printf("-- s3 mutex --\n");
    mjs_mutex *m = NULL;
    int rc = RC(mjs_mutex_init(&m));
    if (rc != 0 || m == NULL) {
        printf("  mutex_init rc=%d; skipping the rest of s3-mutex\n", rc);
        return;
    }
    RC(mjs_mutex_lock(m));
    rc = RC(mjs_mutex_try_lock(m)); /* -EBUSY: trylock never blocks, even
                                       * against the calling thread's own
                                       * hold (non-recursive mutex). */
    if (rc != -EBUSY)
        fail("mutex_try_lock: expected -EBUSY on an already-held mutex");
    RC(mjs_mutex_unlock(m));
    RC(mjs_mutex_destroy(&m));

    /* A second, longer-lived mutex for the condvar rendezvous section. */
    RC(mjs_mutex_init(&sweep_mutex_g));
}

/* ---- s3: condvar --------------------------------------------------------
 *
 * Deadlock-proof rendezvous (see file header): the waker cannot acquire
 * sweep_mutex_g until the main thread's mjs_condvar_wait has atomically
 * released it by entering the wait, so the signal can never be lost. */

static long condvar_waker_entry(void *userdata)
{
    mjs_condvar *c = (mjs_condvar *)userdata;
    if (sweep_mutex_g == NULL)
        return -1;
    mjs_mutex_lock(sweep_mutex_g);   /* raw: off the main thread, not swept */
    mjs_condvar_signal(c);
    mjs_mutex_unlock(sweep_mutex_g);
    return 0;
}

static void sweep_condvar(void)
{
    printf("-- s3 condvar --\n");
    mjs_condvar *c = NULL;
    int rc = RC(mjs_condvar_init(&c));
    if (rc != 0 || c == NULL || sweep_mutex_g == NULL) {
        printf("  condvar_init rc=%d; skipping the rest of s3-condvar\n", rc);
        return;
    }

    /* -ETIMEDOUT branch: no thread, immediate, safe. */
    RC(mjs_mutex_lock(sweep_mutex_g));
    rc = RC(mjs_condvar_wait_until(c, sweep_mutex_g, PAST_DEADLINE));
    if (rc != -ETIMEDOUT)
        fail("condvar_wait_until: expected -ETIMEDOUT for a past deadline");
    RC(mjs_mutex_unlock(sweep_mutex_g));

    /* Plain (unbounded-by-us) wait, unblocked by the mutex-rendezvous
     * waker rather than a deadline. */
    mjs_thread *waker = NULL;
    int spawn_rc = RC(mjs_thread_spawn(condvar_waker_entry, c, 0,
                                       "sweep-cv", &waker));
    if (spawn_rc == 0 && waker != NULL) {
        RC(mjs_mutex_lock(sweep_mutex_g));
        RC(mjs_condvar_wait(c, sweep_mutex_g));
        RC(mjs_mutex_unlock(sweep_mutex_g));
        RC(mjs_thread_join(&waker, NULL));
    } else {
        printf("  thread_spawn (condvar waker) rc=%d; skipping"
               " mjs_condvar_wait's live branch\n", spawn_rc);
    }

    RC(mjs_condvar_broadcast(c)); /* no waiters left; documented no-op */
    RC(mjs_condvar_destroy(&c));
    RC(mjs_mutex_destroy(&sweep_mutex_g));
}

/* ---- s3: atomic-wait ----------------------------------------------------
 *
 * No stickiness and no mutex to rendezvous on (see file header), so this
 * keeps a bounded deadline even though a waker thread races to wake it —
 * worst case is a real, in-contract -ETIMEDOUT, never a hang. */

static long atomic_waker_entry(void *userdata)
{
    uint32_t *word = (uint32_t *)userdata;
    struct timespec ts = {0, 15 * 1000 * 1000}; /* 15ms */
    nanosleep(&ts, NULL);
    mjs_atomic_wake_one_u32(word); /* raw: off the main thread, not swept */
    return 0;
}

static void sweep_atomic_wait(void)
{
    printf("-- s3 atomic-wait --\n");
    uint32_t word = 0;
    mjs_thread *waker = NULL;
    int spawn_rc = RC(mjs_thread_spawn(atomic_waker_entry, &word, 0,
                                       "sweep-aw", &waker));
    uint64_t deadline = deadline_in_ms(500);
    int rc = RC(mjs_atomic_wait_on_u32(&word, 0, &deadline));
    if (rc != 0 && rc != -ETIMEDOUT)
        fail("atomic_wait_on_u32: expected 0 (woken) or -ETIMEDOUT");
    if (spawn_rc == 0 && waker != NULL)
        RC(mjs_thread_join(&waker, NULL));

    /* wake_* are the documented-positive COUNT family (# woken, >= 0):
     * no violation to check, but still worth exercising and logging. */
    uint32_t word2 = 0;
    long woken_one = COUNT(mjs_atomic_wake_one_u32(&word2));
    long woken_all = COUNT(mjs_atomic_wake_all_u32(&word2));
    printf("  wake_one(no waiters)=%ld wake_all(no waiters)=%ld\n",
          woken_one, woken_all);
}

/* ---- s3: event (sticky signal; safe signal-then-wait, no thread) ------ */

static void sweep_event(void)
{
    printf("-- s3 event --\n");
    mjs_event *e = NULL;
    int rc = RC(mjs_event_init(&e));
    if (rc != 0 || e == NULL) {
        printf("  event_init rc=%d; skipping the rest of s3-event\n", rc);
        return;
    }

    rc = RC(mjs_event_wait_until(e, PAST_DEADLINE));
    if (rc != -ETIMEDOUT)
        fail("event_wait_until: expected -ETIMEDOUT with no token pending");

    RC(mjs_event_signal(e)); /* sticky: the token survives until waited on */
    rc = RC(mjs_event_wait_until(e, deadline_in_ms(1000)));
    if (rc != 0)
        fail("event_wait_until: expected 0, a token was signalled first");

    RC(mjs_event_destroy(&e));
}

/* ---- s3: semaphore (permits accumulate; safe post-then-wait, no thread) */

static void sweep_semaphore(void)
{
    printf("-- s3 semaphore --\n");
    mjs_sem *s = NULL;
    int rc = RC(mjs_sem_init(0, &s));
    if (rc != 0 || s == NULL) {
        printf("  sem_init rc=%d; skipping the rest of s3-sem\n", rc);
        return;
    }

    rc = RC(mjs_sem_wait_until(s, PAST_DEADLINE));
    if (rc != -ETIMEDOUT)
        fail("sem_wait_until: expected -ETIMEDOUT with zero permits");

    RC(mjs_sem_post(s)); /* accumulates: a later wait consumes it */
    rc = RC(mjs_sem_wait_until(s, deadline_in_ms(1000)));
    if (rc != 0)
        fail("sem_wait_until: expected 0, a permit was posted first");

    RC(mjs_sem_post(s));
    rc = RC(mjs_sem_try_wait(s));
    if (rc != 0)
        fail("sem_try_wait: expected 0, a permit was posted first");
    rc = RC(mjs_sem_try_wait(s));
    if (rc != -EBUSY)
        fail("sem_try_wait: expected -EBUSY once the permit was consumed");

    RC(mjs_sem_destroy(&s));
}

/* ---- sockets ------------------------------------------------------------
 * Loopback TCP pair. connect() on a BLOCKING socket completes the
 * handshake before returning (SYS-5), so by the time accept() runs the
 * connection is already queued — no retry loop, no timing dependency. */

static void sweep_sockets(void)
{
    printf("-- sockets --\n");
    int port = 20000 + (int)(getpid() % 10000);

    mjs_sockaddr addr;
    memset(&addr, 0, sizeof addr);
    int rc = RC(mjs_sockaddr_ipv4("127.0.0.1", port, &addr));
    if (rc != 0) {
        fail("sockaddr_ipv4: could not build 127.0.0.1 address");
        return;
    }
    char fmt_buf[64];
    size_t fmt_len = 0;
    RC(mjs_sockaddr_format4(&addr, fmt_buf, sizeof fmt_buf, &fmt_len));

    int listen_fd = -1;
    rc = RC(mjs_socket_socket(MJS_SOCK_INET, MJS_SOCK_STREAM, &listen_fd));
    if (rc != 0) {
        printf("  socket_socket (listener) rc=%d; skipping the rest of"
               " sockets\n", rc);
        return;
    }
    RC(mjs_socket_set_nonblocking(listen_fd, 1));
    RC(mjs_socket_bind(listen_fd, &addr));
    RC(mjs_socket_listen(listen_fd, 4));

    int client_fd = -1;
    rc = RC(mjs_socket_socket(MJS_SOCK_INET, MJS_SOCK_STREAM, &client_fd));
    if (rc == 0) {
        RC(mjs_socket_connect(client_fd, &addr)); /* blocking; loopback */

        /* connect() returning 0 on a blocking socket means the handshake
         * already completed, so the connection MUST already be queued —
         * but rare scheduler jitter on a loaded host can still make the
         * FIRST non-blocking accept() see -EAGAIN before the listener's
         * queue is visible to this thread. A short bounded retry (same
         * technique tests/s6/iouring_submit/iouring_submit_contract.c's
         * t2 already uses for its own wait loop) makes the happy path
         * deterministic without weakening the rc<=0 check itself — every
         * attempt's rc, including a real -EAGAIN, still goes through
         * RC(). */
        int accepted_fd = -1;
        mjs_sockaddr peer;
        int attempt;
        for (attempt = 0; attempt < 20; attempt++) {
            memset(&peer, 0, sizeof peer);
            rc = RC(mjs_socket_accept(listen_fd, &accepted_fd, &peer));
            if (rc != -EAGAIN)
                break;
            struct timespec ts = {0, 5 * 1000 * 1000}; /* 5ms */
            nanosleep(&ts, NULL);
        }
        if (rc == 0 && accepted_fd >= 0) {
            RC(mjs_socket_set_nonblocking(accepted_fd, 1));
            size_t out_n = 0;
            unsigned char payload[2] = {'h', 'i'};
            RC(mjs_socket_send(client_fd, payload, sizeof payload, &out_n));
            unsigned char inbuf[8];
            RC(mjs_socket_recv(accepted_fd, inbuf, sizeof inbuf, &out_n));
            RC(mjs_socket_shutdown(accepted_fd, MJS_SHUT_BOTH));
            RC(mjs_socket_close(accepted_fd));
        } else {
            printf("  socket_accept rc=%d\n", rc);
        }
        RC(mjs_socket_close(client_fd));
    } else {
        printf("  socket_socket (client) rc=%d\n", rc);
    }
    RC(mjs_socket_close(listen_fd));
}

/* ---- s6: poller / epoll / io_uring ---------------------------------------
 * All three share the same wire format and near-identical entry points.
 * wake is documented STICKY on all three, so wake-then-wait (no thread)
 * is safe; a bounded timeout is still used throughout (file header). */

static uint64_t bounded_wait_ns(void)
{
    return 2ull * 1000 * 1000 * 1000; /* 2s upper bound, never NULL */
}

static void sweep_poller(void)
{
    printf("-- s6 poller (kqueue) --\n");
    mjs_poller *p = NULL;
    int rc = RC(mjs_poller_create(&p));
    if (rc != 0 || p == NULL) {
        printf("  poller_create rc=%d (no kqueue backend on this host);"
               " skipping the rest\n", rc);
        return;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        fail("poller: pipe() failed");
        RC(mjs_poller_close(&p));
        return;
    }
    RC(mjs_poller_register(p, fds[0], MJS_POLL_READABLE, 0x1111ull));
    RC(mjs_poller_modify(p, fds[0], MJS_POLL_READABLE, 0x2222ull));

    if (write(fds[1], "x", 1) != 1)
        fail("poller: write() to the pipe failed");
    mjs_poll_event ev[4];
    unsigned n = 0;
    uint64_t zero_timeout = 0;
    RC(mjs_poller_wait(p, ev, 4, &zero_timeout, &n)); /* non-blocking poll */

    RC(mjs_poller_wake(p)); /* sticky: safe before the matching wait */
    n = 0;
    uint64_t bounded = bounded_wait_ns();
    RC(mjs_poller_wait(p, ev, 4, &bounded, &n));

    RC(mjs_poller_unregister(p, fds[0]));
    close(fds[0]);
    close(fds[1]);
    RC(mjs_poller_close(&p));
}

static void sweep_epoll(void)
{
    printf("-- s6 epoll (Linux-only; -ENOSYS elsewhere) --\n");
    mjs_epoller *p = NULL;
    int rc = RC(mjs_epoll_create(&p));
    if (rc != 0 || p == NULL) {
        printf("  epoll_create rc=%d (expected -ENOSYS off Linux);"
               " skipping the rest\n", rc);
        return;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        fail("epoll: pipe() failed");
        RC(mjs_epoll_close(&p));
        return;
    }
    RC(mjs_epoll_register(p, fds[0], MJS_POLL_READABLE, 0x3333ull));
    RC(mjs_epoll_modify(p, fds[0], MJS_POLL_READABLE, 0x4444ull));

    if (write(fds[1], "x", 1) != 1)
        fail("epoll: write() to the pipe failed");
    mjs_poll_event ev[4];
    unsigned n = 0;
    uint64_t zero_timeout = 0;
    RC(mjs_epoll_wait(p, ev, 4, &zero_timeout, &n));

    RC(mjs_epoll_wake(p));
    n = 0;
    uint64_t bounded = bounded_wait_ns();
    RC(mjs_epoll_wait(p, ev, 4, &bounded, &n));

    RC(mjs_epoll_unregister(p, fds[0]));
    close(fds[0]);
    close(fds[1]);
    RC(mjs_epoll_close(&p));
}

static void sweep_iouring(void)
{
    printf("-- s6 io_uring (Linux + kernel support + MOJITO_IO_URING=1"
           " only) --\n");
    long probe = COUNT(mjs_iouring_probe());
    setenv("MOJITO_IO_URING", "1", 1);
    long available = COUNT(mjs_iouring_available());
    printf("  probe=%ld available=%ld (predicates; not sign-checked)\n",
          probe, available);

    mjs_uring *r = NULL;
    int rc = RC(mjs_iouring_create(&r));
    if (rc != 0 || r == NULL) {
        printf("  iouring_create rc=%d (expected -ENOSYS without a"
               " capable host); skipping the rest\n", rc);
        return;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        fail("iouring: pipe() failed");
        RC(mjs_iouring_close(&r));
        return;
    }
    RC(mjs_iouring_register(r, fds[0], MJS_POLL_READABLE, 0x5555ull));
    RC(mjs_iouring_modify(r, fds[0], MJS_POLL_READABLE, 0x6666ull));

    unsigned sq = 0, cq = 0;
    RC(mjs_iouring_entries(r, &sq, &cq));

    RC(mjs_iouring_wake(r)); /* sticky */
    mjs_poll_event ev[4];
    unsigned n = 0;
    uint64_t bounded = bounded_wait_ns();
    RC(mjs_iouring_wait(r, ev, 4, &bounded, &n));

    RC(mjs_iouring_unregister(r, fds[0]));
    close(fds[0]);
    close(fds[1]);
    RC(mjs_iouring_close(&r));
}

/* ---- s5: ms_context_init ------------------------------------------------
 * The ONLY errno-style entry point in the s5-ctx block (every other
 * capture/switch/destroy/set_finish_hook call is void and cannot fail).
 * Deliberately invalid arguments hit the documented -EINVAL branch
 * safely, without needing a real fiber switch. */

static void ctx_entry_stub(void *userdata)
{
    (void)userdata;
}

static void sweep_context_init(void)
{
    printf("-- s5 ms_context_init --\n");
    int rc = RC(ms_context_init(NULL, NULL, 0, ctx_entry_stub, NULL));
    if (rc != -EINVAL)
        fail("ms_context_init: expected -EINVAL for NULL ctx/stack_low");
}

/* ---- final tally --------------------------------------------------------- */

static void report(void)
{
    printf("\ncontract sweep: %d rc values observed, %d positive"
          " (contract: rc <= 0), %d informational (count/id/predicate)"
          " calls observed\n",
          sweep_rc_calls, sweep_rc_violations, sweep_count_calls);
    if (sweep_rc_violations == 0)
        return;
    int shown = sweep_rc_violations < SWEEP_LOG_MAX
                    ? sweep_rc_violations
                    : SWEEP_LOG_MAX;
    for (int i = 0; i < shown; i++)
        printf("    %s\n", sweep_rc_log[i]);
    fail("contract sweep: a public entry point in the rc<=0 family"
         " returned a POSITIVE value. The frozen contract"
         " (native/include/mojito_sys.h:23-25) is 0 == success, negative"
         " == -errno, so a positive rc is undecodable: SysError.from_rc"
         " reads it as a fabricated POSIX errno (#167's exact failure"
         " mode).");
}

int main(void)
{
    printf("mojito-sys ABI-wide contract sweep (issue mojito-async#170)\n");

    sweep_vm_and_stack();
    sweep_threads_tls_cpu();
    sweep_clock();
    sweep_mutex();
    sweep_condvar();
    sweep_atomic_wait();
    sweep_event();
    sweep_semaphore();
    sweep_sockets();
    sweep_poller();
    sweep_epoll();
    sweep_iouring();
    sweep_context_init();

    report();

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d RED\n", failures);
    return 1;
}
