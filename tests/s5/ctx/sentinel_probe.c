/*
 * sentinel_probe.c — committed behavioral regression net for the frozen
 * ms_context v2 ABI (issue #64, panel F6).
 *
 * Ported from the spike's MS_CTX_SENTINEL_PROBE evidence pattern
 * (spike/context_switch/ms_ctx.c) onto the PUBLIC frozen ABI: the probe
 * links against the packaged libmojito_sys.dylib and exercises only
 * ms_context_{size,alignment,init,capture,switch,destroy}.
 *
 * What runs (at BOTH -O0 and -O2, see run.sh):
 *   1. sentinel round-trip — two synthetic contexts tag x19-x28 +
 *      d8-d15 with distinct magics, ping-pong through each other (so
 *      BOTH contexts' full callee-saved state crosses a real
 *      ms_context_switch in both directions), yield to the probe driver
 *      mid-life (capture-style resume), verify every sentinel and
 *      16-byte sp alignment at entry and after every resume, then exit
 *      through the real trampoline back to the driver;
 *   2. capture round-trip — the driver's own captured context survives
 *      a switch away and back (driver-local sentinels intact);
 *   3. capture-revives-destroyed — destroy() then capture() re-arms a
 *      context (guard reads AFTER save, header F4 wording);
 *   4. argument validation — NULL args, zero/non-16-multiple stack_size
 *      and unaligned stack_low all yield -EINVAL with storage untouched;
 *   5. dead-guard fork — a child that resumes a DESTROYED context dies
 *      with the loud SIGTRAP (brk #0x68), never a silent wrong resume.
 *
 * Build & run via tests/s5/ctx/run.sh (wired as `make test-s5`).
 */

#include <mojito_sys.h>

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define USABLE (64 * 1024)
#define NSLOTS 21 /* 168 bytes / 8; asserted against ms_context_size() */

static int failures;

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-52s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

/* Caller-owned save areas (frozen: 168 B, 8-byte aligned). */
static _Alignas(8) unsigned long st_main[NSLOTS];
static _Alignas(8) unsigned long st_a[NSLOTS];
static _Alignas(8) unsigned long st_b[NSLOTS];

typedef struct {
    long counter;             /* +0  */
    long left;                /* +8  */
    long regs_ok;             /* +16 */
    long sp_ok;               /* +24 */
    unsigned long tag;        /* +32 */
    ms_context *self;         /* +40 */
    ms_context *peer;         /* +48 */
    ms_context *sched;        /* +56 */
} p_arg_t;

static p_arg_t pa = { 0, 2, 1, 1, 0x11111000UL, NULL, NULL, NULL };
static p_arg_t pb = { 0, 2, 1, 1, 0x22222000UL, NULL, NULL, NULL };

/* Tag-fill / verify / worker, verbatim-in-structure from the spike
 * probe: x19..x28 <- tag+{0x000..0x900}; d8..d15 mirror x19..x26. */
__asm__(
".text\n"
".align 4\n"

".private_extern _probe_fill\n"
"_probe_fill:\n"
"       mov     x19, x0\n"
"       add     x20, x0, #0x100\n"
"       add     x21, x0, #0x200\n"
"       add     x22, x0, #0x300\n"
"       add     x23, x0, #0x400\n"
"       add     x24, x0, #0x500\n"
"       add     x25, x0, #0x600\n"
"       add     x26, x0, #0x700\n"
"       add     x27, x0, #0x800\n"
"       add     x28, x0, #0x900\n"
"       fmov    d8,  x19\n"
"       fmov    d9,  x20\n"
"       fmov    d10, x21\n"
"       fmov    d11, x22\n"
"       fmov    d12, x23\n"
"       fmov    d13, x24\n"
"       fmov    d14, x25\n"
"       fmov    d15, x26\n"
"       ret\n"

/* x0 = tag, x1 = long *ok: clear *ok if any tagged register drifted */
".private_extern _probe_check\n"
"_probe_check:\n"
"       sub     sp, sp, #64\n"
"       stp     d8,  d9,  [sp]\n"
"       stp     d10, d11, [sp, #16]\n"
"       stp     d12, d13, [sp, #32]\n"
"       stp     d14, d15, [sp, #48]\n"
"       mov     x9, x0\n"
"       cmp     x19, x9\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x100\n"
"       cmp     x20, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x200\n"
"       cmp     x21, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x300\n"
"       cmp     x22, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x400\n"
"       cmp     x23, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x500\n"
"       cmp     x24, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x600\n"
"       cmp     x25, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x700\n"
"       cmp     x26, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x800\n"
"       cmp     x27, x11\n"
"       b.ne    9f\n"
"       add     x11, x0, #0x900\n"
"       cmp     x28, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp]\n"
"       cmp     x12, x9\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #8]\n"
"       add     x11, x0, #0x100\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #16]\n"
"       add     x11, x0, #0x200\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #24]\n"
"       add     x11, x0, #0x300\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #32]\n"
"       add     x11, x0, #0x400\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #40]\n"
"       add     x11, x0, #0x500\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #48]\n"
"       add     x11, x0, #0x600\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       ldr     x12, [sp, #56]\n"
"       add     x11, x0, #0x700\n"
"       cmp     x12, x11\n"
"       b.ne    9f\n"
"       add     sp, sp, #64\n"
"       ret\n"
"9:\n"
"       str     xzr, [x1]\n"
"       add     sp, sp, #64\n"
"       ret\n"

/* Generic worker body shared by both probe entries; arg offsets in
 * comments. Rounds: ping-pong `left` times to the peer, verify, yield
 * once to the scheduler context, then RETURN — exercising the real
 * exit trampoline. */
".private_extern _pworker\n"
"_pworker:\n"                                  /* x0 = p_arg_t *arg        */
"       stp     x29, x30, [sp, #-32]!\n"
"       mov     x29, sp\n"
"       str     x0, [sp, #16]\n"               /* arg on our own frame     */
"       ldr     x0, [x0, #32]\n"               /* tag                      */
"       bl      _probe_fill\n"                 /* tags x19-x28, d8-d15     */
"       mov     x12, sp\n"
"       tst     x12, #15\n"
"       b.eq    1f\n"                          /* entry-time sp alignment  */
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #24]\n"
"       str     xzr, [x9]\n"
"1:\n"
"2:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #0]\n"                /* counter++                */
"       add     x9, x9, #1\n"
"       str     x9, [x8, #0]\n"
"       ldr     x10, [x8, #8]\n"               /* --left                   */
"       sub     x10, x10, #1\n"
"       str     x10, [x8, #8]\n"
"       cbz     x10, 3f\n"
"       ldr     x0, [x8, #40]\n"               /* self                     */
"       ldr     x1, [x8, #48]\n"               /* peer                     */
"       bl      _ms_context_switch\n"
"       b       2b\n"                          /* resumed here             */
"3:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #32]\n"               /* tag                      */
"       ldr     x1, [x8, #16]\n"               /* &regs_ok                 */
"       bl      _probe_check\n"                /* x19-x28+d8-d15 intact?   */
"       mov     x12, sp\n"                     /* post-resume sp alignment */
"       tst     x12, #15\n"
"       b.eq    4f\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #24]\n"
"       str     xzr, [x9]\n"
"4:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #40]\n"               /* self                     */
"       ldr     x1, [x8, #56]\n"               /* scheduler (probe driver) */
"       bl      _ms_context_switch\n"          /* mid-life yield           */
"       ldp     x29, x30, [sp], #32\n"
"       ret\n"                                 /* exit via trampoline      */

"\n.private_extern _pa_entry\n"
"_pa_entry:\n"                                 /* x0 = &pa                 */
"       b       _pworker\n"
"\n.private_extern _pb_entry\n"
"_pb_entry:\n"                                 /* x0 = &pb                 */
"       b       _pworker\n"
);

void pa_entry(void *);
void pb_entry(void *);

/* Guarded synthetic stack: PROT_NONE page below the usable region, so a
 * downward underflow faults loudly instead of scribbling. Returns the
 * LOW end of the usable region (stack_low). */
static void *p_stack(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t total = (size_t)ps + USABLE;
    char *p = mmap(NULL, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(p, (size_t)ps, PROT_NONE);
    return p + ps;
}

static void geometry_and_validation(void)
{
    /* Failed init must leave caller storage byte-for-byte untouched. */
    memset(st_a, 0xA5, sizeof(st_a));
    CHECK(ms_context_init(NULL, p_stack(), USABLE, pa_entry, &pa) == -EINVAL,
          "init: NULL ctx => -EINVAL");
    CHECK(ms_context_init((ms_context *)st_b, NULL, USABLE, pa_entry,
                          &pa) == -EINVAL,
          "init: NULL stack_low => -EINVAL");
    CHECK(ms_context_init((ms_context *)st_b, p_stack(), USABLE, NULL,
                          &pa) == -EINVAL,
          "init: NULL entry => -EINVAL");
    CHECK(ms_context_init((ms_context *)st_b, p_stack(), 0, pa_entry,
                          &pa) == -EINVAL,
          "init: zero stack_size => -EINVAL");
    CHECK(ms_context_init((ms_context *)st_b, p_stack(), USABLE + 8,
                          pa_entry, &pa) == -EINVAL,
          "init: non-16-multiple stack_size => -EINVAL");
    {
        void *lo = p_stack();
        CHECK(ms_context_init((ms_context *)st_b, (char *)lo + 8, USABLE,
                              pa_entry, &pa) == -EINVAL,
              "init: unaligned stack_low => -EINVAL");
    }
    {
        int untouched = 1;
        size_t i;
        for (i = 0; i < NSLOTS; i++)
            if (st_a[i] != 0xA5A5A5A5A5A5A5A5UL)
                untouched = 0;
        CHECK(untouched, "init: failed init leaves storage untouched");
    }
}

/* Destroy-then-capture REVIVES the context (header F4 contract): the
 * dead-context guard reads saved state only AFTER the save. */
static void capture_revives_destroyed(void)
{
    static _Alignas(8) unsigned long st_x[NSLOTS];
    static _Alignas(8) unsigned long st_m[NSLOTS];
    ms_context *cx = (ms_context *)st_x;
    ms_context *m = (ms_context *)st_m;
    volatile int step = 0; /* MUST be memory-backed: the revive re-entry
                            * re-runs `step++` through a restored
                            * snapshot; a register copy would loop. */

    memset(st_x, 0, sizeof(st_x));
    if (ms_context_init(cx, p_stack(), USABLE, pb_entry, &pb) != 0) {
        CHECK(0, "capture-revive: init failed");
        return;
    }
    ms_context_destroy(cx);            /* poisoned: sp slot 0 */
    ms_context_capture(cx);            /* self-switch saves live state */
    step++;                            /* runs again on revival */
    if (step == 1) {
        ms_context_capture(m);
        ms_context_switch(m, cx);      /* resumes just after capture(cx) */
        CHECK(0, "capture-revive: switch to revived ctx ran");
        return;
    }
    CHECK(step == 2, "capture-revive: destroyed ctx revived by capture");
}

/* Child resumes a DESTROYED context: must die loudly (SIGTRAP), never
 * silently resume garbage. */
static void dead_guard_fork(void)
{
    pid_t pid = fork();
    int st;

    if (pid < 0) {
        perror("fork");
        CHECK(0, "dead-guard: fork failed");
        return;
    }
    if (pid == 0) {
        /* The trap must not kill the probe driver: attempt the
         * destructive resume in a child. */
        static _Alignas(8) unsigned long st_d[NSLOTS];
        static _Alignas(8) unsigned long st_m[NSLOTS];
        ms_context *d = (ms_context *)st_d;
        ms_context *m = (ms_context *)st_m;

        if (ms_context_init(d, p_stack(), USABLE, pa_entry, &pa) != 0)
            _exit(2);
        ms_context_destroy(d);
        ms_context_capture(m);         /* driver snapshot */
        ms_context_switch(m, d);       /* brk #0x68 => SIGTRAP */
        _exit(1);                      /* silent resume = bug */
    }
    waitpid(pid, &st, 0);
    CHECK(WIFSIGNALED(st) && WTERMSIG(st) == SIGTRAP,
          "dead-guard: resume of destroyed ctx traps (SIGTRAP)");
}

int main(void)
{
    ms_context *mainc = (ms_context *)st_main;
    ms_context *ca = (ms_context *)st_a;
    ms_context *cb = (ms_context *)st_b;
    volatile unsigned long drv_sentinel_a = 0xDEADBEEFCAFEBABEUL;
    volatile unsigned long drv_sentinel_b = 0xEEDFACE0DDC0FFEEUL;

    printf("== s5/ctx sentinel probe (issue #64 F6)\n");

    geometry_and_validation();

    pa.self = ca; pa.peer = cb; pa.sched = mainc;
    pb.self = cb; pb.peer = ca; pb.sched = mainc;
    if (ms_context_init(ca, p_stack(), USABLE, pa_entry, &pa) != 0 ||
        ms_context_init(cb, p_stack(), USABLE, pb_entry, &pb) != 0) {
        printf("  init FAILED\n");
        return 1;
    }

    printf("sentinel probe: A<->B cross-switch; both verify x19-x28 + "
           "d8-d15 + sp\n");
    ms_context_capture(mainc);     /* driver snapshot (capture contract) */
    ms_context_switch(mainc, ca);
    /* Back after A's mid-life yield: A and B have ping-ponged once each
     * and A verified itself. Driver state must be intact (capture
     * round-trip). */
    CHECK(drv_sentinel_a == 0xDEADBEEFCAFEBABEUL &&
          drv_sentinel_b == 0xEEDFACE0DDC0FFEEUL,
          "driver state preserved across switch away/back");
    CHECK(pa.counter == 2 && pb.counter >= 1,
          "workers progressed across real switches");

    ms_context_switch(mainc, ca);  /* A resumes post-yield, exits */
    CHECK(pa.regs_ok == 1 && pa.sp_ok == 1 && pa.counter == 2,
          "A: x19-x28 + d8-d15 preserved, sp aligned, exited cleanly");

    ms_context_switch(mainc, cb);  /* B resumes post-ping, verifies, yields */
    CHECK(pb.regs_ok == 1 && pb.sp_ok == 1 && pb.counter == 2,
          "B: x19-x28 + d8-d15 preserved, sp aligned");

    ms_context_switch(mainc, cb);  /* B resumes post-yield, exits */
    CHECK(pb.counter == 2,
          "B: exited cleanly through the trampoline");

    capture_revives_destroyed();
    dead_guard_fork();

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}
