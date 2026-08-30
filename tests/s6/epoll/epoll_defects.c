/*
 * tests/s6/epoll/epoll_defects.c — RED driver for issue #162.
 *
 * LINUX ONLY, AND UNEXECUTED AS WRITTEN.  This file was authored on a
 * macOS/arm64 host where every mjs_epoll_* entry point is the
 * detect-and-exclude -ENOSYS stub, so none of the four cases below has ever
 * run.  That is precisely the finding: this backend shipped with every
 * behavioural conformance row printing UNSUPPORTED-PLATFORM, and it needs
 * the Linux CI lane from mojito-async#141 before anything here means
 * anything.  run.sh in this directory exits 2 (environment) rather than 0 on
 * a non-Linux host, so a skip can never be mistaken for a pass.
 *
 * The three defects, all in native/posix/mjs_epoll.c:
 *
 * 1. UNBOUNDED LINEAR PROBE (:76-83).  mjs_epoll_slot loops
 *
 *        while (p->table_fd[h] != -1 && p->table_fd[h] != fd)
 *            h = (h + 1u) & (MJS_EPOLL_TABLE_CAP - 1u);
 *
 *    with no iteration bound.  The -ENOSPC guard at :140-142 is therefore
 *    UNREACHABLE: the probe only ever returns an empty-or-matching slot, and
 *    when neither exists — 256 live registrations, a new fd — it never
 *    returns at all.  257 concurrently registered fds is a hard hang of the
 *    reactor thread, not an error.  mjs_iouring.c's uring_slot bounds its
 *    probe to r_cap and tracks r_count with the comment "cannot livelock",
 *    so the author knew; the epoll copy has neither.
 *
 * 2. DELETION BREAKS THE PROBE CHAIN.  mjs_epoll_unregister writes
 *    table_fd[slot] = -1 in the MIDDLE of a probe chain, and mjs_epoll_slot
 *    stops at the first -1.  Two colliding fds A and B, A registered first
 *    and B probed past it: once A unregisters, B's readiness resolves to an
 *    empty slot and is dropped on EVERY wait, while level-triggered epoll
 *    re-reports it every time.  The reactor spins at 100% and B's waiter
 *    never wakes.
 *
 * 3. TIMEOUT TRUNCATION.  :114-122 computes ns / 1'000'000 truncating toward
 *    zero, so any timeout in (0, 1ms) becomes tm = 0, an immediate return.
 *    A timer wheel scheduling 100us sleeps spins the reactor at 100% until
 *    each deadline.  kqueue passes full timespec precision, so the same code
 *    has different CPU behaviour per platform.
 *
 * 4. NO CLOEXEC (mjs_socket.c:144 socket(af, type, 0), :223 plain accept).
 *    mjs_epoll.c:170-173 correctly uses EPOLL_CLOEXEC, so this is
 *    inconsistency rather than policy.  Every listener and accepted
 *    connection leaks into any child the process spawns.
 *
 * BOUNDING.  Case 1's failure mode is an infinite loop inside the library,
 * so it runs under alarm(); SIGALRM makes the case FAIL loudly instead of
 * wedging the suite.  A test for a hang that can itself hang is not a test.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mojito_sys.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

/* Two descriptor numbers congruent mod MJS_EPOLL_TABLE_CAP (256), so they
 * hash to the same home slot and B is probed one past A. */
#define A_FD 300
#define B_FD 556

static int failures;

static void fail(const char *what)
{
    printf("  - %s\n", what);
    failures++;
}

/* ---- case 1: a full table must return -ENOSPC, not spin forever -------- */

static sigjmp_buf probe_jmp;

static void on_alarm(int sig)
{
    (void)sig;
    siglongjmp(probe_jmp, 1);
}

static void case_full_table(void)
{
    mjs_epoller *p = NULL;
    int fds[600];
    volatile int n = 0;   /* live across siglongjmp */
    int i, rc;
    struct sigaction sa, old;

    if (mjs_epoll_create(&p) != 0) {
        fail("full-table: mjs_epoll_create failed");
        return;
    }

    /* MJS_EPOLL_TABLE_CAP is 256 and is not configurable; 257 live
     * registrations is the first fd with nowhere to go. */
    for (i = 0; i < 300; i++) {
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
            break;
        close(sv[1]);
        fds[n++] = sv[0];
    }
    if (n < 258) {
        fail("full-table: could not open enough descriptors to fill the table");
        goto done;
    }

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, &old);

    if (sigsetjmp(probe_jmp, 1) != 0) {
        alarm(0);
        sigaction(SIGALRM, &old, NULL);
        fail("full-table: mjs_epoll_register NEVER RETURNED on a full table."
             " mjs_epoll_slot's probe has no iteration bound, so the -ENOSPC"
             " guard at mjs_epoll.c:140-142 is unreachable and 257 live"
             " registrations hang the reactor thread outright.");
        goto done;
    }

    rc = 0;
    alarm(5);
    for (i = 0; i < n; i++) {
        rc = mjs_epoll_register(p, fds[i], MJS_POLL_READABLE,
                                (uint64_t)(i + 1));
        if (rc != 0)
            break;
    }
    alarm(0);
    sigaction(SIGALRM, &old, NULL);

    if (rc != -ENOSPC)
        fail("full-table: filling the table past its capacity returned"
             " something other than -ENOSPC");

done:
    for (i = 0; i < n; i++)
        close(fds[i]);
    mjs_epoll_close(&p);
}

/* ---- case 2: unregistering A must not orphan B's chain slot ------------ */

static void case_deleted_chain(void)
{
    mjs_epoller *p = NULL;
    mjs_poll_event ev[8];
    int a[2], b[2];
    int rc, got;

    if (mjs_epoll_create(&p) != 0) {
        fail("deleted-chain: mjs_epoll_create failed");
        return;
    }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, a) != 0 ||
        socketpair(AF_UNIX, SOCK_STREAM, 0, b) != 0) {
        fail("deleted-chain: socketpair failed");
        mjs_epoll_close(&p);
        return;
    }

    /* The collision has to be FORCED, or the case proves nothing. The hash
     * is fd * 2654435761 masked to 8 bits; 2654435761 is odd, so that map is
     * a bijection mod 256 and two descriptors collide exactly when they are
     * congruent mod 256. dup2 puts them at chosen numbers 256 apart, so A
     * lands in the home slot and B is probed one past it.
     *
     * (My first version registered two arbitrary descriptors and the case
     * passed on Linux: they simply did not collide, so there was no chain to
     * break. A test that cannot fail is worse than no test.) */
    if (dup2(a[0], A_FD) < 0 || dup2(b[0], B_FD) < 0) {
        fail("deleted-chain: dup2 could not place the colliding descriptors");
        goto done;
    }
    close(a[0]); a[0] = A_FD;
    close(b[0]); b[0] = B_FD;

    if (mjs_epoll_register(p, a[0], MJS_POLL_READABLE, 0xAAu) != 0 ||
        mjs_epoll_register(p, b[0], MJS_POLL_READABLE, 0xBBu) != 0) {
        fail("deleted-chain: registration failed");
        goto done;
    }

    if (mjs_epoll_unregister(p, a[0]) != 0) {
        fail("deleted-chain: unregister(A) failed");
        goto done;
    }

    /* Make B readable and ask for it. */
    if (write(b[1], "x", 1) != 1) {
        fail("deleted-chain: write to B failed");
        goto done;
    }
    {
        uint64_t tmo = 200ull * 1000ull * 1000ull;   /* 200ms */
        unsigned out_n = 0;
        int wrc = mjs_epoll_wait(p, ev, 8, &tmo, &out_n);
        got = (wrc == 0) ? (int)out_n : -1;
    }
    if (got <= 0) {
        fail("deleted-chain: B's readiness was NOT delivered after A"
             " unregistered. mjs_epoll_unregister writes table_fd[slot] = -1"
             " in the middle of a probe chain and mjs_epoll_slot stops at the"
             " first -1, so B's token can no longer be resolved. Level-"
             " triggered epoll re-reports B on every wait, so the reactor"
             " also spins at 100%.");
        goto done;
    }
    rc = 0;
    for (int i = 0; i < got; i++)
        if (ev[i].token == 0xBBu)
            rc = 1;
    if (!rc)
        fail("deleted-chain: an event was delivered but B's token 0xBB was"
             " not among them; the token table lost the registration");

done:
    close(a[0]); close(a[1]); close(b[0]); close(b[1]);
    mjs_epoll_close(&p);
}

/* ---- case 3: a sub-millisecond timeout must actually wait ------------- */

static void case_sub_ms_timeout(void)
{
    mjs_epoller *p = NULL;
    mjs_poll_event ev[4];
    struct timeval t0, t1;
    long long elapsed_us;

    if (mjs_epoll_create(&p) != 0) {
        fail("sub-ms: mjs_epoll_create failed");
        return;
    }

    {
        uint64_t tmo = 500ull * 1000ull;             /* 500us */
        unsigned out_n = 0;
        gettimeofday(&t0, NULL);
        (void)mjs_epoll_wait(p, ev, 4, &tmo, &out_n);
        gettimeofday(&t1, NULL);
    }
    elapsed_us = (long long)(t1.tv_sec - t0.tv_sec) * 1000000
               + (long long)(t1.tv_usec - t0.tv_usec);

    /* Generous floor: a correct implementation waits ~500us. Truncation to
     * epoll_wait(timeout = 0) returns in single-digit microseconds. */
    if (elapsed_us < 300) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "sub-ms: a 500us wait returned after %lldus. ns / 1'000'000"
                 " truncates toward zero (mjs_epoll.c:114-122), so any"
                 " timeout under 1ms becomes epoll_wait(timeout = 0) and the"
                 " reactor spins at 100%% until the deadline.", elapsed_us);
        fail(msg);
    }
    mjs_epoll_close(&p);
}

/* ---- case 4: a listener must not leak into a child -------------------- */

static void case_cloexec(void)
{
    /* Goes through the real mjs_socket_socket entry point (issue #181),
     * not a bare socket() of our own -- a raw call here would check
     * fcntl's own default rather than what the library under test
     * actually does, and could never observe a fix to it either. */
    int fd = -1;
    if (mjs_socket_socket(MJS_SOCK_INET, MJS_SOCK_STREAM, &fd) != 0) {
        fail("cloexec: mjs_socket_socket failed");
        return;
    }
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        fail("cloexec: fcntl(F_GETFD) failed");
    } else if ((flags & FD_CLOEXEC) == 0) {
        fail("cloexec: a socket created the way mjs_socket_open creates one"
             " has no FD_CLOEXEC, so every listener and accepted connection"
             " leaks into any child the process ever spawns. mjs_epoll.c"
             " uses EPOLL_CLOEXEC correctly, so this is inconsistency rather"
             " than policy.");
    }
    close(fd);
}

int main(void)
{
    printf("S6 epoll defects (issue #162)\n");

    /* There is no mjs_epoll_available() predicate; mjs_epoll_create returns
     * exactly -ENOSYS when the backend is the detect-and-exclude stub.
     * Exit 2, an ENVIRONMENT result, never 0: a lane that could not run must
     * not be counted as a lane that passed (mojito-async#141). */
    {
        mjs_epoller *probe = NULL;
        int rc = mjs_epoll_create(&probe);
        if (rc == -ENOSYS) {
            printf("  epoll backend is the -ENOSYS stub on this host.\n");
            printf("RESULT: UNSUPPORTED-PLATFORM\n");
            return 2;
        }
        if (rc != 0) {
            printf("  mjs_epoll_create failed with %d\n", rc);
            printf("RESULT: ENVIRONMENT\n");
            return 2;
        }
        mjs_epoll_close(&probe);
    }

    case_full_table();
    case_deleted_chain();
    case_sub_ms_timeout();
    case_cloexec();

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d RED\n", failures);
    return 1;
}
