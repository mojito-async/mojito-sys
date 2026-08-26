/*
 * conformance_probe.c — S5.5 ctx permanent conformance suite (issue #68):
 * promote the S0 spike's T1..T14 semantics into a committed regression net
 * against the PACKAGED libmojito_sys.dylib.
 *
 * The spike's T1..T14 are Mojo tests; the spike itself is a feasibility
 * prototype and is NOT copied here. Each T row below is the C equivalent of
 * the spec §6.5 / §38.6 semantic, exercised through the PUBLIC frozen ABI
 * (ms_context_{size,alignment,init,capture,switch,destroy},
 * mjs_stack_alloc/mjs_stack_free) so an ABI defect localizes to the C layer
 * (spec §23 harness). Rows (T14 is a shell symbol-audit row in run.sh):
 *
 *   T1  local-address stability — a stack-local's address and value are
 *       identical after suspension and resumption.
 *   T2  borrowed-reference validity — a pointer to stack-backed storage
 *       held across a switch remains usable (read+write) after resume.
 *   T3  destructor exactness — a managed value is constructed once and
 *       destroyed exactly once; never at a yield, never duplicated.
 *   T4  error after resume — an error signalled after a resume propagates
 *       out of the worker through the completion trampoline to the caller.
 *   T5  error before yield and cleanup — an error path taken before a
 *       planned yield still runs exactly-once cleanup on the managed value.
 *   T6  repeated switching — A<->B ping-pong with a mutable stack-local
 *       verified every iteration; >= 1,000,000 real switches (§23 stress).
 *   T7  nested call depth — a 64-frame recursion suspends at the deepest
 *       frame; every ancestor frame's canary is intact after resume/unwind.
 *   T8  integer-register preservation — x19..x28 tagged and verified.
 *   T9  SIMD/FP preservation — d8..d15 tagged and verified.
 *   T10 stack alignment — 16-byte sp at trampoline entry and after resume.
 *   T11 TLS continuity — OS-thread TLS (pthread key + C _Thread_local)
 *       unchanged across switches.
 *   T12 synthetic-stack entry/exit — a fresh context enters a trampoline,
 *       yields, resumes, exits through the completion path; the stack is
 *       then freed and an equal-size replacement reallocated cleanly.
 *   T13 guard-page behavior — top-of-stack writable, and overflow past the
 *       low end into the guard page faults in a forked child instead of
 *       silently scribbling adjacent memory.
 *
 * T8/T9 worker is a PURE-ASM routine (Mach-O): it deliberately loads
 * callee-saved registers with per-context tags and re-verifies them after a
 * real ms_context_switch, so the backend's register preservation is proven
 * without any C-level assumption that those registers survive (spec §23.1).
 *
 * Build & run via tests/s5/ctx/conformance/run.sh (wired into
 * tests/s5/ctx/run.sh); runs at BOTH -O0 and -O2.
 */

#include <mojito_sys.h>

#include <pthread.h>

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define USABLE (64 * 1024)   /* usable bytes on each synthetic stack     */
#define REC 256              /* caller-owned save area, >= ms_context_size() */
#define STRESS_GOAL 500000L  /* A<->B round trips => 1,000,000 switches  */
#define DEEP_N 64            /* nested recursion depth (spike depth)     */

static int failures;

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-58s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

/* ---- guarded synthetic stack: PROT_NONE page below the usable region --- */

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

/* ==================== T8 / T9 / T10 — register + alignment =============
 * Pure-asm worker (Mach-O, machine-local like the sentinel spike probe).
 * arg layout (all offsets in bytes):
 *   +0 counter  +8 regs_ok(int)  +16 fpu_ok  +24 sp_ok
 *   +32 tag  +40 self  +48 peer  +56 sched            */
typedef struct {
    long counter;
    long regs_ok;
    long fpu_ok;
    long sp_ok;
    unsigned long tag;
    ms_context *self;
    ms_context *peer;
    ms_context *sched;
} t89_arg_t;

__asm__(
".text\n"
".align 4\n"

".private_extern _conf_fill\n"
"_conf_fill:\n"                       /* x0 = tag */
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

".private_extern _conf_check_int\n"   /* x0=tag, x1=&regs_ok */
"_conf_check_int:\n"
"       cmp     x19, x0\n"
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
"       ret\n"
"9:\n"
"       str     xzr, [x1]\n"
"       ret\n"

".private_extern _conf_check_fpu\n"   /* x0=tag, x1=&fpu_ok */
"_conf_check_fpu:\n"
"       sub     sp, sp, #64\n"
"       stp     d8,  d9,  [sp]\n"
"       stp     d10, d11, [sp, #16]\n"
"       stp     d12, d13, [sp, #32]\n"
"       stp     d14, d15, [sp, #48]\n"
"       ldr     x12, [sp]\n"
"       cmp     x12, x0\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x100\n"
"       ldr     x12, [sp, #8]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x200\n"
"       ldr     x12, [sp, #16]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x300\n"
"       ldr     x12, [sp, #24]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x400\n"
"       ldr     x12, [sp, #32]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x500\n"
"       ldr     x12, [sp, #40]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x600\n"
"       ldr     x12, [sp, #48]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     x13, x0, #0x700\n"
"       ldr     x12, [sp, #56]\n"
"       cmp     x12, x13\n"
"       b.ne    9f\n"
"       add     sp, sp, #64\n"
"       ret\n"
"9:\n"
"       str     xzr, [x1]\n"
"       add     sp, sp, #64\n"
"       ret\n"

/* Worker: fill callee-saved regs with tag; ping-pong the peer thrice;
 * after each resume verify int+fpu regs and sp alignment; then yield to
 * the scheduler once and return (completion trampoline). */
".private_extern _conf_worker\n"
"_conf_worker:\n"                            /* x0 = t89_arg_t *a       */
"       stp     x29, x30, [sp, #-32]!\n"
"       mov     x29, sp\n"
"       str     x0, [sp, #16]\n"
"       ldr     x0, [x0, #32]\n"             /* tag                    */
"       bl      _conf_fill\n"
"       mov     x12, sp\n"
"       tst     x12, #15\n"
"       b.eq    1f\n"                        /* entry sp aligned?      */
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #24]\n"
"       str     xzr, [x9]\n"
"1:\n"
"2:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #0]\n"              /* counter++              */
"       add     x9, x9, #1\n"
"       str     x9, [x8, #0]\n"
"       cmp     x9, #3\n"                    /* 3 throbs of the pair   */
"       b.ge    4f\n"
"       ldr     x0, [x8, #40]\n"             /* self                   */
"       ldr     x1, [x8, #48]\n"             /* peer                   */
"       bl      _ms_context_switch\n"
"       b       2b\n"                        /* resumed here           */
"4:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #32]\n"             /* tag                    */
"       add     x1, x8, #8\n"                /* &regs_ok               */
"       bl      _conf_check_int\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #32]\n"
"       add     x1, x8, #16\n"               /* &fpu_ok                */
"       bl      _conf_check_fpu\n"
"       mov     x12, sp\n"
"       tst     x12, #15\n"
"       b.eq    5f\n"                        /* post-resume aligned?   */
"       ldr     x8, [sp, #16]\n"
"       ldr     x9, [x8, #24]\n"
"       str     xzr, [x9]\n"
"5:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #40]\n"             /* self                   */
"       ldr     x1, [x8, #56]\n"             /* sched                  */
"       bl      _ms_context_switch\n"        /* mid-life yield         */
"       ldp     x29, x30, [sp], #32\n"
"       ret\n"                               /* exit via trampoline    */

"\n.private_extern _conf_a_entry\n"
"_conf_a_entry:\n"
"       b       _conf_worker\n"
"\n.private_extern _conf_b_entry\n"
"_conf_b_entry:\n"
"       b       _conf_worker\n"
);

void conf_a_entry(void *);
void conf_b_entry(void *);

static t89_arg_t t89_a, t89_b;

static void test_t89(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ca[REC];
    _Alignas(8) unsigned long cb[REC];
    ms_context *sched = (ms_context *)drv;
    ms_context *cx_a = (ms_context *)ca;
    ms_context *cx_b = (ms_context *)cb;

    memset(&t89_a, 0, sizeof(t89_a));
    memset(&t89_b, 0, sizeof(t89_b));
    t89_a.regs_ok = t89_a.fpu_ok = t89_a.sp_ok = 1;
    t89_b.regs_ok = t89_b.fpu_ok = t89_b.sp_ok = 1;
    t89_a.tag = 0x88880000UL;
    t89_b.tag = 0x99990000UL;
    t89_a.self = cx_a; t89_a.peer = cx_b; t89_a.sched = sched;
    t89_b.self = cx_b; t89_b.peer = cx_a; t89_b.sched = sched;
    if (ms_context_init(cx_a, p_stack(), USABLE, conf_a_entry, &t89_a) != 0 ||
        ms_context_init(cx_b, p_stack(), USABLE, conf_b_entry, &t89_b) != 0) {
        CHECK(0, "T8/T9 register preservation: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx_a);  /* A<->B throbs, A yields once     */
    CHECK((t89_a.counter + t89_b.counter) >= 3 &&
              t89_a.regs_ok == 1 && t89_b.regs_ok == 1,
          "T8 integer regs: x19..x28 preserved across cross-switch");
    CHECK(t89_a.fpu_ok == 1 && t89_b.fpu_ok == 1,
          "T9 SIMD regs: d8..d15 preserved across cross-switch");
    CHECK(t89_a.sp_ok == 1 && t89_b.sp_ok == 1,
          "T10 sp alignment: 16-byte sp at entry and after every resume");
    ms_context_switch(sched, cx_a);  /* A post-yield, exits             */
    ms_context_switch(sched, cx_b);  /* B post-yield, exits             */
}

/* ========================= T1 — local-address stability ================ */

typedef struct {
    ms_context *self, *sched;
    long ok;
    uintptr_t addr0, addr1;
    long val0, val1;
} t1_arg_t;

static void t1_entry(void *v)
{
    t1_arg_t *a = v;
    volatile long local = 0x1122334455667788L;

    a->addr0 = (uintptr_t)&local;
    a->val0 = local;
    ms_context_switch(a->self, a->sched);       /* suspend */
    if ((uintptr_t)&local != a->addr0) a->ok = 0;   /* resume: identical */
    if (local != a->val0) a->ok = 0;
    local = 0xDEADBEEF00000001L;
    a->addr1 = (uintptr_t)&local; a->val1 = local;
    ms_context_switch(a->self, a->sched);       /* suspend again */
    if ((uintptr_t)&local != a->addr1) a->ok = 0;
    if (local != a->val1) a->ok = 0;
    /* return => completion trampoline => permanent switch back to driver */
}

static void test_t1(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t1_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.self = cx;
    arg.sched = sched;
    if (ms_context_init(cx, p_stack(), USABLE, t1_entry, &arg) != 0) {
        CHECK(0, "T1 local-address stability: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* entry -> suspend 1 */
    ms_context_switch(sched, cx);   /* resume -> suspend 2 */
    ms_context_switch(sched, cx);   /* resume -> exit */
    CHECK(arg.addr0 == arg.addr1 && arg.ok == 1,
          "T1 local-address stability: address+value survive 2 suspends");
}

/* ===================== T2 — borrowed-reference validity ================ */

typedef struct {
    ms_context *self, *sched;
    long ok;
    unsigned long *borrowed;     /* pointer to driver stack-backed value */
} t2_arg_t;

static void t2_entry(void *v)
{
    t2_arg_t *a = v;
    volatile unsigned long my = 0x5A5A5A5A00000000UL + (uintptr_t)a;
    uintptr_t my_addr = (uintptr_t)&my;

    ms_context_switch(a->self, a->sched);       /* hold ref across switch */
    if (*(volatile unsigned long *)a->borrowed != 0xCAFECAFE00000002UL) a->ok = 0;
    if ((uintptr_t)&my != my_addr) a->ok = 0;
    if (my != 0x5A5A5A5A00000000UL + (uintptr_t)a) a->ok = 0;
    *(volatile unsigned long *)a->borrowed = 0x42; /* mutate; driver observes */
    ms_context_switch(a->self, a->sched);       /* back, then exit */
}

static void test_t2(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t2_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;
    volatile unsigned long borrowed = 0xCAFECAFE00000001UL;

    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.self = cx;
    arg.sched = sched;
    arg.borrowed = (unsigned long *)&borrowed;
    if (ms_context_init(cx, p_stack(), USABLE, t2_entry, &arg) != 0) {
        CHECK(0, "T2 borrowed-reference validity: init failed");
        return;
    }
    borrowed = 0xCAFECAFE00000002UL;
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* entry -> yield */
    ms_context_switch(sched, cx);   /* resume: reads borrowed, writes 0x42 */
    CHECK(arg.ok == 1 && borrowed == 0x42,
          "T2 borrowed-reference validity: ref live across switch (R+W)");
}

/* ===================== T3 — destructor exactness ======================= */

static long g_constr, g_destr;

typedef struct {
    ms_context *self, *sched;
    long ok;
} t3_arg_t;

static void t3_entry(void *v)
{
    t3_arg_t *a = v;

    g_constr++;                             /* constructed once */
    ms_context_switch(a->self, a->sched);   /* yield 1 */
    if (g_destr != 0) a->ok = 0;            /* NOT destroyed at yield */
    ms_context_switch(a->self, a->sched);   /* yield 2 */
    if (g_destr != 0) a->ok = 0;
    g_destr++;                              /* destroyed exactly once here */
}

static void test_t3(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t3_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    g_constr = g_destr = 0;
    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.self = cx;
    arg.sched = sched;
    if (ms_context_init(cx, p_stack(), USABLE, t3_entry, &arg) != 0) {
        CHECK(0, "T3 destructor exactness: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);
    CHECK(g_constr == 1 && g_destr == 0, "T3 constructed once, not at yield");
    ms_context_switch(sched, cx);
    CHECK(g_constr == 1 && g_destr == 0,
          "T3 not destroyed/duplicated at yield");
    ms_context_switch(sched, cx);           /* runs g_destr++; exits */
    CHECK(g_constr == 1 && g_destr == 1 && arg.ok == 1,
          "T3 destructor exactness: destroyed exactly once at completion");
}

/* ================ T4 — error after resume (raises after resume) ======== */

typedef struct {
    ms_context *self, *sched;
    long resume_count;
    long error_signalled;
} t4_arg_t;

static void t4_entry(void *v)
{
    t4_arg_t *a = v;

    ms_context_switch(a->self, a->sched);   /* suspend before any error */
    a->resume_count++;
    if (a->resume_count == 1) {
        /* "raise" AFTER resumption: signal an error that must propagate
         * out of the worker through the completion trampoline to the
         * driver (the C equivalent of Mojo's raises-after-resume). */
        a->error_signalled = 1;
        return;                             /* propagate through return path */
    }
    a->error_signalled = 2;                 /* resumed a second time: not
                                               reached (worker exited) */
}

static void test_t4(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t4_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    memset(&arg, 0, sizeof(arg));
    arg.self = cx;
    arg.sched = sched;
    if (ms_context_init(cx, p_stack(), USABLE, t4_entry, &arg) != 0) {
        CHECK(0, "T4 error after resume: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* entry -> suspend */
    ms_context_switch(sched, cx);   /* resume -> error signalled -> exit */
    CHECK(arg.resume_count == 1 && arg.error_signalled == 1,
          "T4 error after resume: error propagates via completion path");
}

/* ============= T5 — error before yield and cleanup ===================== */

typedef struct {
    ms_context *self, *sched;
    long should_fail;
    long error_seen, cleanup_done;
} t5_arg_t;

static void t5_entry(void *v)
{
    t5_arg_t *a = v;

    g_constr++;                        /* acquire managed value */
    if (a->should_fail) {
        /* error path BEFORE the planned yield: cleanup runs exactly once
         * and the worker exits without ever reaching the yield. */
        g_destr++;                     /* release once */
        a->cleanup_done++;
        a->error_seen = 1;
        return;                        /* exit through trampoline */
    }
    ms_context_switch(a->self, a->sched);   /* planned yield (not reached) */
    g_destr++;
}

static void test_t5(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t5_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    g_constr = g_destr = 0;
    memset(&arg, 0, sizeof(arg));
    arg.self = cx;
    arg.sched = sched;
    arg.should_fail = 1;
    if (ms_context_init(cx, p_stack(), USABLE, t5_entry, &arg) != 0) {
        CHECK(0, "T5 error before yield and cleanup: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* worker hits error path, cleans up, exits */
    CHECK(arg.error_seen == 1 && arg.cleanup_done == 1 &&
              g_constr == 1 && g_destr == 1,
          "T5 error before yield: exactly-once cleanup, no double free");
}

/* ===================== T6 — repeated switching ========================= */

typedef struct {
    long goal, iter;
    long bad;
    uintptr_t laddr;
    ms_context *self, *peer, *sched;
    int finished;
} t6_arg_t;

static void t6_a_entry(void *v)
{
    t6_arg_t *a = v;
    volatile long local = 0x11110000L;
    uintptr_t la = (uintptr_t)&local;

    for (a->iter = 0; a->iter < a->goal; a->iter++) {
        local = a->iter + 0x11110000L;
        if ((uintptr_t)&local != la) a->bad = 1;
        ms_context_switch(a->self, a->peer);
        if (local != a->iter + 0x11110000L) a->bad = 1; /* value intact */
    }
    a->finished = 1;
    ms_context_switch(a->self, a->sched);
    ms_context_switch(a->self, a->sched);   /* second resume => exit */
}

static void t6_b_entry(void *v)
{
    t6_arg_t *a = v;
    volatile long local = 0x22220000L;
    uintptr_t la = (uintptr_t)&local;

    for (a->iter = 0; a->iter < a->goal; a->iter++) {
        local = a->iter + 0x22220000L;
        if ((uintptr_t)&local != la) a->bad = 1;
        ms_context_switch(a->self, a->peer);
        if (local != a->iter + 0x22220000L) a->bad = 1;
    }
    a->finished = 1;
    ms_context_switch(a->self, a->sched);
    ms_context_switch(a->self, a->sched);   /* exit */
}

static void test_t6(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ca[REC];
    _Alignas(8) unsigned long cb[REC];
    t6_arg_t arg_a, arg_b;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx_a = (ms_context *)ca;
    ms_context *cx_b = (ms_context *)cb;

    memset(&arg_a, 0, sizeof(arg_a));
    memset(&arg_b, 0, sizeof(arg_b));
    arg_a.goal = arg_b.goal = STRESS_GOAL;
    arg_a.self = cx_a; arg_a.peer = cx_b; arg_a.sched = sched;
    arg_b.self = cx_b; arg_b.peer = cx_a; arg_b.sched = sched;
    if (ms_context_init(cx_a, p_stack(), USABLE, t6_a_entry, &arg_a) != 0 ||
        ms_context_init(cx_b, p_stack(), USABLE, t6_b_entry, &arg_b) != 0) {
        CHECK(0, "T6 repeated switching: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx_a);         /* A<->B ping-pong; A hands off
                                               after its FULL loop. During the
                                               ping-pong each worker ran STRESS_GOAL
                                               iterations = 2*STRESS_GOAL switches. */
    CHECK(arg_a.bad == 0 && arg_b.bad == 0 &&
              arg_a.iter == STRESS_GOAL && 2 * STRESS_GOAL >= 1000000L,
          "T6 repeated switching: >=1,000,000 switches, state intact every iter");
    ms_context_switch(sched, cx_a);         /* A post-yield, exits */
    ms_context_switch(sched, cx_b);         /* B resumes, finishes loop, yields */
    CHECK(arg_b.iter == STRESS_GOAL && arg_b.finished == 1 && arg_b.bad == 0,
          "T6 repeated switching: B completes full loop cleanly");
    ms_context_switch(sched, cx_b);         /* B exits */
    CHECK(arg_a.bad == 0 && arg_b.bad == 0,
          "T6 repeated switching: A+B exited cleanly through trampoline");
}

/* ===================== T7 — nested call depth ========================== */

typedef struct {
    ms_context *self, *sched;
    long ok;
    long magic;
} t7_arg_t;

static void t7_recurse(t7_arg_t *a, int depth)
{
    volatile long canary = a->magic + (long)(depth * 1000UL);
    uintptr_t caddr = (uintptr_t)&canary;

    if (depth == 0) {
        /* deepest frame: suspend below the whole chain, then resume */
        ms_context_switch(a->self, a->sched);
        if ((uintptr_t)&canary != caddr || canary != a->magic) a->ok = 0;
        return;
    }
    t7_recurse(a, depth - 1);
    if ((uintptr_t)&canary != caddr || canary != a->magic + depth * 1000L)
        a->ok = 0;                          /* ancestor frame intact */
}

static void t7_entry(void *v)
{
    t7_arg_t *a = v;
    t7_recurse(a, DEEP_N);
}

static void test_t7(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t7_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.magic = 0x0123456789ABCDEFUL;
    arg.self = cx;
    arg.sched = sched;
    if (ms_context_init(cx, p_stack(), USABLE, t7_entry, &arg) != 0) {
        CHECK(0, "T7 nested call depth: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* descends 64, suspends at deepest */
    ms_context_switch(sched, cx);   /* resume: unwind, verify canaries */
    CHECK(arg.ok == 1,
          "T7 nested call depth: 64 frames intact after suspend/resume");
}

/* ===================== T11 — TLS continuity ============================ */

static pthread_key_t g_key;
static _Thread_local long g_tl_sentinel = 0;

typedef struct {
    long ok;
    ms_context *self, *sched;
} t11_arg_t;

static void t11_entry(void *v)
{
    t11_arg_t *a = v;

    if (pthread_getspecific(g_key) != (void *)0x11111111UL) a->ok = 0;
    if (g_tl_sentinel != 0x22222222L) a->ok = 0;
    ms_context_switch(a->self, a->sched);   /* yield */
    if (pthread_getspecific(g_key) != (void *)0x11111111UL) a->ok = 0;
    if (g_tl_sentinel != 0x22222222L) a->ok = 0;
    ms_context_switch(a->self, a->sched);   /* back, then exit */
}

static void test_t11(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t11_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;

    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.self = cx;
    arg.sched = sched;
    if (pthread_key_create(&g_key, NULL) != 0) {
        CHECK(0, "T11 TLS continuity: pthread_key_create failed");
        return;
    }
    pthread_setspecific(g_key, (void *)0x11111111UL);
    g_tl_sentinel = 0x22222222L;
    if (ms_context_init(cx, p_stack(), USABLE, t11_entry, &arg) != 0) {
        CHECK(0, "T11 TLS continuity: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);
    ms_context_switch(sched, cx);
    CHECK(arg.ok == 1 && pthread_getspecific(g_key) == (void *)0x11111111UL,
          "T11 TLS continuity: OS-thread TLS unchanged across switches");
    pthread_key_delete(g_key);
}

/* ============== T12 — synthetic-stack entry/exit + reclaim ============= */

typedef struct {
    long ok;
    unsigned long mask;      /* bit0 heap scratch, bit1 own-stack sentinel */
    ms_context *self, *sched;
} t12_arg_t;

static unsigned long g_scratch[64];

static void t12_entry(void *v)
{
    t12_arg_t *a = v;
    unsigned long i;
    volatile unsigned long *below;

    for (i = 0; i < 64; i++) g_scratch[i] = 0xD0000000UL + i; /* heap */
    /* sentinels on OUR synthetic stack, just below the current frame */
    below = (volatile unsigned long *)(((char *)&i) - 128);
    for (i = 0; i < 16; i++) below[i] = 0xE0000000UL + i;
    ms_context_switch(a->self, a->sched);   /* enter, then yield */
    for (i = 0; i < 64; i++)
        if (g_scratch[i] != 0xD0000000UL + i) a->mask |= 1u;
    for (i = 0; i < 16; i++)
        if (((volatile unsigned long *)((char *)&i - 128))[i] !=
                0xE0000000UL + i)
            a->mask |= 2u;                  /* own-stack sentinels intact */
    ms_context_switch(a->self, a->sched);   /* resume, then exit */
}

static void test_t12(void)
{
    _Alignas(8) unsigned long drv[REC];
    _Alignas(8) unsigned long ctxr[REC];
    t12_arg_t arg;
    ms_context *sched = (ms_context *)drv;
    ms_context *cx = (ms_context *)ctxr;
    void *base = NULL, *guard_low = NULL;
    size_t top = 0;
    size_t reserve = 1u << 20, commit = 1u << 20, guard = 1u << 20;

    memset(&arg, 0, sizeof(arg));
    arg.ok = 1;
    arg.self = cx;
    arg.sched = sched;
    if (ms_context_init(cx, p_stack(), USABLE, t12_entry, &arg) != 0) {
        CHECK(0, "T12 synthetic-stack entry/exit: init failed");
        return;
    }
    ms_context_capture(sched);
    ms_context_switch(sched, cx);   /* entry: fill scratch+stack, yield */
    ms_context_switch(sched, cx);   /* resume: verify, exit through trampoline */
    CHECK((arg.mask & 3u) == 0,
          "T12 synthetic entry/exit: heap+own-stack sentinels intact");

    /* reclaim: free a guarded stack, then reallocate an equal-size one. */
    if (mjs_stack_alloc(reserve, commit, guard, &base, &guard_low,
                        &top) != 0) {
        CHECK(0, "T12 reclaim: mjs_stack_alloc failed");
        return;
    }
    CHECK((uintptr_t)guard_low > (uintptr_t)base && top > (uintptr_t)guard_low,
          "T12 reclaim: guarded stack carved (guard_low > base)");
    *(volatile unsigned char *)(top - 1) = 0x5A;      /* highest usable byte */
    CHECK(*(volatile unsigned char *)(top - 1) == 0x5A,
          "T12 reclaim: highest usable byte write/read OK");
    if (mjs_stack_free(&base) != 0 || base != NULL) {
        CHECK(0, "T12 reclaim: mjs_stack_free failed");
        return;
    }
    if (mjs_stack_alloc(reserve, commit, guard, &base, &guard_low,
                        &top) != 0) {
        CHECK(0, "T12 reclaim: equal-size realloc after free failed");
        return;
    }
    *(volatile unsigned char *)(top - 1) = 0xA5;
    CHECK(*(volatile unsigned char *)(top - 1) == 0xA5,
          "T12 reclaim: equal-size replacement stack usable after free");
    mjs_stack_free(&base);
}

/* ================ T13 — guard-page behavior (issue #68 red->green) =====
 * The RED (TDD) commit (T13_USE_GUARDED_ALLOC == 0) carried a callER-
 * PROVIDED RAW buffer with NO guard page below the usable range: an
 * overflow silently writes into the adjacent still-RW anonymous region and
 * the child SURVIVES — T13 correctly FAILS (missing guard == silent
 * corruption path, spec S0-T13). The GREEN commit (== 1) carves the stack
 * with mjs_stack_alloc (the S1 frozen allocator that paints a PROT_NONE
 * guard page), so the overflow raises a controlled SIGBUS/SIGSEGV in the
 * child and T13 PASSES. */

#ifndef T13_USE_GUARDED_ALLOC
#define T13_USE_GUARDED_ALLOC 0
#endif

static void t13_fault_child(void)
{
    if (T13_USE_GUARDED_ALLOC) {
        void *base = NULL, *guard_low = NULL;
        size_t top = 0;
        size_t reserve = 1u << 20, commit = 1u << 20, guard = 1u << 20;

        if (mjs_stack_alloc(reserve, commit, guard, &base, &guard_low,
                            &top) != 0)
            _exit(6);
        *(volatile unsigned char *)(top - 1) = 0x5A;   /* top usable byte RW */
        /* overflow past the LOW end into the PROT_NONE guard page: fault */
        *(volatile unsigned char *)((uintptr_t)guard_low - 1) = 0x5A;
        _exit(1);   /* survived the guard write = silent-corruption bug */
    } else {
        /* RED: raw caller-provided buffer, NO guard page. The region below
         * the usable range is STILL RW anonymous memory, so the overflow
         * writes silently and the child survives. */
        size_t total = (1u << 20) + (1u << 20);   /* usable + extra RW tail */
        char *p = mmap(NULL, total, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) _exit(6);
        *(volatile unsigned char *)((uintptr_t)p + (1u << 20) - 1) = 0x5A;
        *(volatile unsigned char *)((uintptr_t)p + (1u << 20) - 2) = 0x5A;
        _exit(1);   /* survived = guard absent, silent adjacent write */
    }
}

static void test_t13(void)
{
    pid_t pid;
    int st;
    int faulted;

    fflush(stdout);
    pid = fork();
    if (pid < 0) { perror("fork"); CHECK(0, "T13 guard: fork failed"); return; }
    if (pid == 0) { t13_fault_child(); _exit(1); }
    waitpid(pid, &st, 0);
    faulted = WIFSIGNALED(st) &&
              (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV);
    CHECK(faulted,
          "T13 guard-page: overflow faults (SIGBUS/SIGSEGV), no silent corruption");
}

/* ======================================================================= */

int main(void)
{
    printf("== s5/ctx conformance probe (issue #68: T1..T13)\n");
    CHECK(ms_context_size() >= 168, "geometry: ms_context_size >= v2 168B");
    CHECK(ms_context_alignment() == 8, "geometry: ms_context_alignment == 8");

    test_t1();
    test_t2();
    test_t3();
    test_t4();
    test_t5();
    test_t6();       /* 1,000,000 switches; the long pole, once per opt */
    test_t7();
    test_t89();      /* T8 + T9 + T10 */
    test_t11();
    test_t12();
    test_t13();

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}
