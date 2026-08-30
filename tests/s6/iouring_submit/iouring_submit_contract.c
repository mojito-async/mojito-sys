/*
 * tests/s6/iouring_submit/iouring_submit_contract.c — RED driver for #167.
 *
 * THE DEFECT.  native/posix/mjs_iouring.c states its return contract at
 * :9-10, and native/include/mojito_sys.h:1163-1164 repeats it:
 *
 *   0 == success; negative == -errno; out-params untouched on failure
 *
 * One chain in the file breaks it:
 *
 *   ioring_enter          :79-86    returns (int)r, the NUMBER OF SQES
 *                                   CONSUMED, and the wrapper comment
 *                                   (:71-74) says so honestly.
 *   uring_submit          :199-211  passes that straight through and
 *                                   documents no return contract at all.
 *   uring_submit_poll_add :267-283  its docstring promises "Returns 0 or
 *                                   negative errno"; its last line is
 *                                   `return uring_submit(u, 0, 0);`, the
 *                                   count.  The convention flips here, and
 *                                   only in a comment the code contradicts.
 *
 * Two callers then read the count as an error, and both use `!= 0` where
 * every other call site in the file correctly uses `< 0`:
 *
 *   mjs_iouring_create    :450-462  arms the wake poll (exactly ONE SQE, so
 *                                   io_uring_enter reports 1), reads the 1
 *                                   as failure, closes the wake eventfd,
 *                                   unmaps all three rings, closes the ring
 *                                   fd, frees the handle and returns +1 —
 *                                   neither 0 nor -errno, so no caller can
 *                                   decode it.  On a kernel that supports
 *                                   io_uring, a ring can NEVER be created.
 *   mjs_iouring_register  :505-513  the fresh-registration path does the
 *                                   same, and worse: it returns +1 AFTER
 *                                   the poll_add reached the kernel but
 *                                   BEFORE the fd is recorded in the table,
 *                                   so a live kernel poll is orphaned, its
 *                                   readiness is consumed and dropped by
 *                                   uring_drain_cq's unknown-seq path, and
 *                                   the caller is told a registration failed
 *                                   that half-happened.
 *
 * WHY BOTH SITES ARE PINNED HERE.  Fixing the check at the create site
 * alone converts this bug into the register one, so t2 below drives a live
 * ring through register/wait.  Today it is blocked (there is no ring); with
 * a create-site-only fix it runs and goes red; only a fix at the shared
 * helper turns both green.
 *
 * WHY IT SURFACES AS A PERMISSION ERROR.  IoUringPoller.create()
 * (mojito_sys/io/platform/iouring.mojo:137-146) feeds any non-zero rc to
 * raise_errno, and SysError.from_rc (mojito_sys/abi/errors.mojo:237-240)
 * decodes a positive rc as a positive errno code, so the +1 reaches users as
 * "mojito-sys error: POSIX errno 1 (EPERM)" — a fabricated permission error
 * pointing at entirely the wrong subsystem.
 *
 * ENVIRONMENT GUARD.  This lane needs a NATIVE Linux kernel with io_uring.
 * Under Rosetta / qemu linux/amd64 emulation io_uring_setup returns ENOSYS,
 * and Docker's default seccomp profile refuses the syscall too.  In either
 * case mjs_iouring_probe() returns 0 and this lane exits 2
 * (UNSUPPORTED-PLATFORM), never 0 and never 1: "I could not measure" must
 * never be recorded as "nothing wrong" (mojito-async#141).  That trap is not
 * hypothetical — the agent who filed #167 hit it first and read the
 * emulated ENOSYS as a pass.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mojito_sys.h"

#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

#define TOKEN ((uint64_t)0x5167167167167167ULL)

/* A value no allocator will ever return, parked in the out-slot so "handle
 * delivered" and "out-param untouched on failure" are distinguishable. */
#define SENTINEL ((mjs_uring *)(uintptr_t)0xD00DFEEDCAFEBABEULL)

static int failures;
static mjs_uring *ring;          /* live ring after t1, or NULL */

static void fail(const char *what)
{
    printf("  - %s\n", what);
    failures++;
}

/* ---- t3: the contract sweep, woven through every other case ------------
 *
 * Every mjs_iouring_* rc this lane observes goes through here.  The whole
 * class of defect is "a positive value escaped an entry point declared to
 * return 0 or -errno", so checking the sign of every rc costs nothing and
 * catches a third site if one ever appears. */

#define SWEEP_MAX 8

static int sweep_calls;
static int sweep_violations;
static char sweep_log[SWEEP_MAX][96];

/* Violations are recorded, not reported, so the per-case output stays in
 * order and t3 reads as the single distinct assertion it is. */
static int rc_check(const char *call, int rc)
{
    sweep_calls++;
    if (rc > 0) {
        if (sweep_violations < SWEEP_MAX)
            snprintf(sweep_log[sweep_violations],
                     sizeof sweep_log[0], "%s returned %+d", call, rc);
        sweep_violations++;
    }
    return rc;
}
#define RC(call) rc_check(#call, (call))

static void t3_contract_sweep(void)
{
    int i;

    printf("  t3 contract sweep: %d mjs_iouring_* rc values observed,"
           " %d positive (contract: rc <= 0)\n", sweep_calls,
           sweep_violations);
    if (sweep_violations == 0)
        return;
    for (i = 0; i < sweep_violations && i < SWEEP_MAX; i++)
        printf("      %s\n", sweep_log[i]);
    fail("t3 contract sweep: an mjs_iouring_* entry point returned a POSITIVE"
         " value. The frozen contract (mjs_iouring.c:9-10, mojito_sys.h:"
         "1163-1164) is 0 == success, negative == -errno, so a positive rc is"
         " undecodable: SysError.from_rc reads it as a positive errno and the"
         " caller gets a fabricated POSIX error.");
}

/* Open descriptors right now.  Equal counts either side of a failed create
 * mean the ring fd AND the wake eventfd were opened and closed again, i.e.
 * the ring really was built and then destroyed rather than never built. */
static int open_fds(void)
{
    DIR *d = opendir("/proc/self/fd");
    struct dirent *e;
    int n = 0;

    if (d == NULL)
        return -1;
    while ((e = readdir(d)) != NULL)
        if (e->d_name[0] != '.')
            n++;
    closedir(d);
    return n - 1; /* the readdir fd itself */
}

/* ---- t1: create must return EXACTLY 0 and deliver a handle ------------- */

static void t1_create_contract(void)
{
    mjs_uring *u = SENTINEL;
    int before = open_fds();
    int rc;
    int after;

    rc = RC(mjs_iouring_create(&u));
    after = open_fds();

    printf("  t1 mjs_iouring_create rc=%d  out-slot=%s  open fds %d -> %d\n",
           rc, (u == SENTINEL) ? "sentinel untouched"
                               : (u == NULL ? "NULL" : "handle"),
           before, after);

    if (rc == 0) {
        if (u == SENTINEL || u == NULL) {
            fail("t1 create: returned 0 but stored no handle in the out-slot");
            return;
        }
        ring = u;
        return;
    }

    if (rc > 0) {
        char msg[512];
        snprintf(msg, sizeof msg,
                 "t1 create: mjs_iouring_create returned %+d after"
                 " mjs_iouring_available() said the backend was usable. That"
                 " is the SQE count from io_uring_enter arming the wake poll,"
                 " carried through uring_submit and uring_submit_poll_add and"
                 " then read as failure by the `rc != 0` check at :450-462."
                 " Create tore down the ring it had just finished building"
                 " (open fds %d -> %d: the ring fd and the wake eventfd were"
                 " both closed again) and returned a value that is neither 0"
                 " nor -errno.",
                 rc, before, after);
        fail(msg);
    } else {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "t1 create: mjs_iouring_create returned %d (%s) after"
                 " mjs_iouring_available() said the backend was usable",
                 rc, strerror(-rc));
        fail(msg);
    }
}

/* ---- t2: register + wait through the LIVE ring ------------------------
 *
 * This is the second broken site.  It is deliberately driven through the
 * public API on a real ring rather than asserted about, so that a fix
 * applied only at the create site cannot make this lane green. */

static void t2_register_delivers(void)
{
    int fds[2];
    mjs_poll_event ev[8];
    unsigned n = 0;
    uint64_t timeout_ns = 1000ULL * 1000ULL * 1000ULL; /* 1s per attempt */
    int rc;
    int attempt;

    if (ring == NULL) {
        fail("t2 register: BLOCKED — driving register needs a live ring and"
             " t1 could not produce one. This case is what pins the SECOND"
             " misread (mjs_iouring_register :505-513): patch only create's"
             " check to `rc < 0` and t1 goes green while this case runs and"
             " goes RED, because register returns +1 after the poll_add has"
             " reached the kernel but before the fd is recorded in the table."
             " Only normalising the shared uring_submit_poll_add helper turns"
             " both green.");
        return;
    }

    if (pipe(fds) != 0) {
        fail("t2 register: pipe() failed");
        return;
    }

    rc = RC(mjs_iouring_register(ring, fds[0], MJS_POLL_READABLE, TOKEN));
    printf("  t2 mjs_iouring_register rc=%d\n", rc);
    if (rc != 0) {
        char msg[512];
        snprintf(msg, sizeof msg,
                 "t2 register: mjs_iouring_register returned %d on a live"
                 " ring; the contract is 0 or -errno. A positive value is the"
                 " SQE count again, returned by the `rc != 0` check at"
                 " :505-513 BEFORE the fd is recorded in the table: the"
                 " kernel holds a live poll whose user_data the table cannot"
                 " resolve, readiness on that fd is consumed and dropped by"
                 " uring_drain_cq's unknown-seq path, and the caller is told"
                 " the registration failed when it half-happened.", rc);
        fail(msg);
        close(fds[0]);
        close(fds[1]);
        return;
    }

    if (write(fds[1], "x", 1) != 1) {
        fail("t2 register: write to the pipe failed");
        close(fds[0]);
        close(fds[1]);
        return;
    }

    for (attempt = 0; attempt < 4 && n == 0; attempt++) {
        rc = RC(mjs_iouring_wait(ring, ev, 8u, &timeout_ns, &n));
        if (rc == -EINTR)
            continue;
        if (rc != 0) {
            char msg[192];
            snprintf(msg, sizeof msg,
                     "t2 register: mjs_iouring_wait returned %d", rc);
            fail(msg);
            close(fds[0]);
            close(fds[1]);
            return;
        }
    }

    printf("  t2 mjs_iouring_wait delivered=%u", n);
    if (n >= 1)
        printf(" token=0x%llx fd=%d", (unsigned long long)ev[0].token,
               ev[0].fd);
    printf("\n");

    if (n != 1u) {
        char msg[384];
        snprintf(msg, sizeof msg,
                 "t2 register: a byte is pending on a registered pipe and"
                 " mjs_iouring_wait delivered %u events, expected exactly 1."
                 " A registration that reported success but never reached the"
                 " table drops its readiness on the unknown-seq path.", n);
        fail(msg);
    } else if (ev[0].token != TOKEN) {
        char msg[192];
        snprintf(msg, sizeof msg,
                 "t2 register: delivered token 0x%llx, expected 0x%llx",
                 (unsigned long long)ev[0].token, (unsigned long long)TOKEN);
        fail(msg);
    } else if (ev[0].fd != fds[0]) {
        fail("t2 register: delivered event carries the wrong descriptor");
    }

    RC(mjs_iouring_unregister(ring, fds[0]));
    close(fds[0]);
    close(fds[1]);
}

int main(void)
{
    struct utsname un;

    printf("S6 io_uring submit-return contract (issue #167)\n");

    if (uname(&un) == 0)
        printf("  host: %s %s %s\n", un.sysname, un.release, un.machine);

    /* Environment guard, deliberately BEFORE the capability flag is set:
     * probe() is host kernel support alone. Rosetta/qemu linux/amd64 and
     * Docker's default seccomp profile both make io_uring_setup return
     * ENOSYS, and a lane that cannot issue the syscall must report that,
     * not a verdict. */
    if (!mjs_iouring_probe()) {
        printf("  mjs_iouring_probe() == 0: this kernel cannot create an"
               " io_uring.\n");
        printf("  Needs a NATIVE Linux kernel with io_uring. Emulated"
               " linux/amd64 (Rosetta/qemu) and Docker's default seccomp"
               " profile both fail io_uring_setup with ENOSYS.\n");
        printf("RESULT: UNSUPPORTED-PLATFORM\n");
        return 2;
    }

    /* The backend is capability-flagged (spec §28). The flag is set HERE so
     * the lane cannot silently degrade into a skip because a caller forgot
     * to export it; the guard above already established host support. */
    setenv("MOJITO_IO_URING", "1", 1);
    if (!mjs_iouring_available()) {
        printf("  mjs_iouring_available() == 0 with MOJITO_IO_URING=1 set and"
               " mjs_iouring_probe() == 1.\n");
        printf("RESULT: ENVIRONMENT\n");
        return 2;
    }
    printf("  probe=1 available=1 (MOJITO_IO_URING=1) — the backend's only"
           " success configuration, exercised for real.\n");

    t1_create_contract();
    t2_register_delivers();

    if (ring != NULL)
        RC(mjs_iouring_close(&ring));

    t3_contract_sweep();

    if (failures == 0) {
        printf("RESULT: all green\n");
        return 0;
    }
    printf("RESULT: %d RED\n", failures);
    return 1;
}
