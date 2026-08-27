/*
 * lifecycle_probe.c — S5.3 acceptance net (#66): the SELF-CONTAINED,
 * PER-CONTEXT context lifecycle replacing the spike-era global return-to
 * table. Links against the packaged libmojito_sys.dylib and drives only
 * the public s5-ctx ABI.
 *
 * What runs (at BOTH -O0 and -O2, see run.sh):
 *   1. more than 64 SIMULTANEOUS live contexts (128) all initialized,
 *      suspended mid-life at once, then completed — the deleted global
 *      table's hard limit is gone (spec §22 flow, issue #66);
 *   2. >= 4 OS threads running INDEPENDENT sustained switch pairs —
 *      the multi-thread capability the global-table design forbade
 *      (per-context exclusivity only);
 *   3. completion hook fires EXACTLY ONCE per finished context, with
 *      userdata passed through (de-vacuates the T12 synthetic-stack
 *      completion stage, PR#21 BLOCK);
 *   3b. finish-hook REGISTRY semantics: a hook registered after the
 *      context has FINISHED never fires, and destroy discards any
 *      registered hook;
 *   3c. DIRTY-STORAGE regression: record tails poisoned to 0xAA before
 *      init — state words must be written full-width so the misuse
 *      guards still fire on dirty caller storage (panel P1-H1);
 *   4. re-resume of a FINISHED context traps loudly (SIGTRAP), observed
 *      in a forked child;
 *   5. re-resume of a RUNNING context (two threads on ONE context —
 *      genuine caller misuse) traps loudly (SIGTRAP), observed in a
 *      forked child;
 *   6. misaligned synthetic stack at make is rejected loudly and
 *      deterministically (-EINVAL, storage untouched, process survives),
 *      observed in a forked child; the backend brk #0x64 remains the
 *      internal defense-in-depth behind ms_context_init's validation.
 *
 * Build & run via tests/s5/ctx/lifecycle/run.sh (wired into
 * tests/s5/ctx/run.sh).
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

#define USABLE (64 * 1024)
/* Record slots: frozen v2 168 bytes + 4-slot lifecycle tail = 200. */
#define NSLOTS 25
#define BULK_NCTX 128 /* > 64: the old global table's capacity */
#define PAIRS_THREADS 4
#define PAIRS_ITERS 5000
#define NHOOKS 8

static int failures;

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-52s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

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

/* Plain 16-aligned stack without a guard page (bulk/thread tests trade
 * the guard for footprint). Returns stack_low. */
static void *plain_stack(void)
{
    void *p = NULL;
    if (posix_memalign(&p, 16, USABLE) != 0) {
        perror("posix_memalign");
        exit(2);
    }
    memset(p, 0, USABLE);
    return p;
}

/* ---- fork harness: destructive misuse must die LOUDLY in a child ------ */

static int child_result(void (*fn)(void), int want_signal, int want_status)
{
    pid_t pid;
    int st;

    fflush(stdout);
    pid = fork();
    if (pid < 0) {
        perror("fork");
        return 0;
    }
    if (pid == 0) {
        fn();
        _exit(0); /* surviving a should-trap child = silent bug */
    }
    waitpid(pid, &st, 0);
    if (want_signal)
        return WIFSIGNALED(st) && WTERMSIG(st) == want_signal &&
               !WIFEXITED(st);
    return WIFEXITED(st) && WEXITSTATUS(st) == want_status;
}

/* Poison a record's v3 lifecycle TAIL (bytes 168..199) with 0xAA before
 * init: the header allows any caller storage (struct member, heap block,
 * stack slot) with NO zero-init precondition, so the backend must write
 * FULL-width state words — a 32-bit str would leave these dirty bytes
 * above bit 31 and every state validation would misread (panel P1-H1). */
static void poison_tail(void *rec)
{
    memset((unsigned char *)rec + 168, 0xAA, 32);
}

/* ---- shared trivial entry: does some work, then returns ---------------- */

typedef struct {
    long marker;
} work_arg_t;

static void work_entry(void *v)
{
    work_arg_t *a = v;

    a->marker += 100; /* some work before returning through the trampoline */
}

/* ---- 1. >64 simultaneous live contexts -------------------------------- */

typedef struct {
    long counter;
    ms_context *self;
    ms_context *sched;
} bulk_arg_t;

static void bulk_entry(void *v)
{
    bulk_arg_t *a = v;

    a->counter++;
    ms_context_switch(a->self, a->sched); /* suspend mid-life */
    a->counter++;
    /* return => trampoline completion => permanent switch-out */
}

static _Alignas(8) unsigned long bulk_slots[BULK_NCTX][NSLOTS];
static bulk_arg_t bulk_args[BULK_NCTX];

static void test_bulk_live(void)
{
    static _Alignas(8) unsigned long st_main[NSLOTS];
    ms_context *mainc = (ms_context *)st_main;
    long live = 0, done = 0;
    int i;

    for (i = 0; i < BULK_NCTX; i++) {
        bulk_args[i].counter = 0;
        bulk_args[i].self = (ms_context *)bulk_slots[i];
        bulk_args[i].sched = mainc;
        if (ms_context_init(bulk_args[i].self, p_stack(), USABLE,
                            bulk_entry, &bulk_args[i]) != 0) {
            CHECK(0, "bulk: init failed");
            return;
        }
    }

    ms_context_capture(mainc);
    /* Pass 1: every context runs to its mid-life suspension point and
     * hands control back — ALL BULK_NCTX are simultaneously LIVE. */
    for (i = 0; i < BULK_NCTX; i++)
        ms_context_switch(mainc, bulk_args[i].self);
    for (i = 0; i < BULK_NCTX; i++)
        live += (bulk_args[i].counter == 1);

    /* Pass 2: resume each; it finishes through the real trampoline. */
    for (i = 0; i < BULK_NCTX; i++)
        ms_context_switch(mainc, bulk_args[i].self);
    for (i = 0; i < BULK_NCTX; i++)
        done += (bulk_args[i].counter == 2);

    CHECK(BULK_NCTX > 64 && live == BULK_NCTX,
          "bulk: >64 simultaneous live contexts (table limit gone)");
    CHECK(done == BULK_NCTX,
          "bulk: every context exited cleanly through the trampoline");
}

/* ---- 2. >=4 threads, independent sustained switch pairs ---------------- */

typedef struct {
    long ac, bc;
    long iters;
    long switches_seen;
    ms_context *ca, *cb, *sched;
} pair_arg_t;

static void pair_a_entry(void *v)
{
    pair_arg_t *a = v;
    long i;

    for (i = 0; i < a->iters; i++) {
        a->ac++;
        ms_context_switch(a->ca, a->cb);
    }
    a->switches_seen = a->ac + a->bc;
    ms_context_switch(a->ca, a->sched); /* hand control to the driver */
    /* resumed once more by the driver, then returns => trampoline */
}

static void pair_b_entry(void *v)
{
    pair_arg_t *a = v;
    long i;

    for (i = 0; i < a->iters; i++) {
        a->bc++;
        ms_context_switch(a->cb, a->ca);
    }
    ms_context_switch(a->cb, a->sched);
}

static void *pair_thread(void *v)
{
    /* Per-thread storage: these MUST be locals (thread stacks), never
     * statics — four threads own disjoint records by design (#66). */
    _Alignas(8) unsigned long st_drv[NSLOTS];
    _Alignas(8) unsigned long st_a[NSLOTS];
    _Alignas(8) unsigned long st_b[NSLOTS];
    pair_arg_t *arg = v;
    ms_context *drv = (ms_context *)st_drv;
    intptr_t ok = 1;

    arg->ac = arg->bc = arg->switches_seen = 0;
    arg->ca = (ms_context *)st_a;
    arg->cb = (ms_context *)st_b;
    arg->sched = drv;
    if (ms_context_init(arg->ca, plain_stack(), USABLE, pair_a_entry,
                        arg) != 0 ||
        ms_context_init(arg->cb, plain_stack(), USABLE, pair_b_entry,
                        arg) != 0)
        return (void *)0;

    ms_context_capture(drv);
    ms_context_switch(drv, arg->ca); /* pairs ping-pong, then A yields */
    ok &= (arg->ac == arg->iters && arg->bc == arg->iters);
    ms_context_switch(drv, arg->cb); /* B resumes post-ping, yields */
    ok &= (arg->ac == arg->iters && arg->bc == arg->iters);
    ms_context_switch(drv, arg->ca); /* A returns through trampoline */
    ms_context_switch(drv, arg->cb); /* B returns through trampoline */
    ok &= (arg->switches_seen == 2 * arg->iters);

    return (void *)ok;
}

static void test_threads_pairs(void)
{
    pthread_t th[PAIRS_THREADS];
    pair_arg_t args[PAIRS_THREADS];
    long ok = 0;
    int i, spawned = 0;

    for (i = 0; i < PAIRS_THREADS; i++) {
        args[i].iters = PAIRS_ITERS;
        if (pthread_create(&th[i], NULL, pair_thread, &args[i]) != 0) {
            CHECK(0, "threads: pthread_create failed");
            break;
        }
        spawned++;
    }
    for (i = 0; i < spawned; i++) {
        void *ret = NULL;
        pthread_join(th[i], &ret);
        ok += (ret == (void *)1);
    }
    CHECK(ok == PAIRS_THREADS,
          "threads: >=4 threads ran independent sustained switch pairs");
}

/* ---- 3. completion hook fires exactly once ----------------------------- */

static unsigned long hook_hits[NHOOKS];
static uintptr_t hook_got_ud[NHOOKS];

static void hook_fn(void *ud)
{
    uintptr_t i = (uintptr_t)ud;

    if (i < NHOOKS) {
        hook_hits[i]++;
        hook_got_ud[i] = i;
    }
}

static _Alignas(8) unsigned long hook_slots[NHOOKS][NSLOTS];

static void test_finish_hook(void)
{
    static _Alignas(8) unsigned long st_main[NSLOTS];
    ms_context *mainc = (ms_context *)st_main;
    static work_arg_t hargs[NHOOKS]; /* outlives nothing special; static
                                      * keeps addresses stable across the
                                      * switches for easy inspection */
    unsigned long total = 0;
    int i, ok = 1;

    memset(hook_hits, 0, sizeof(hook_hits));
    memset(hook_got_ud, 0, sizeof(hook_got_ud));
    for (i = 0; i < NHOOKS; i++) {
        hargs[i].marker = 0;
        if (ms_context_init((ms_context *)hook_slots[i], p_stack(), USABLE,
                            work_entry, &hargs[i]) != 0) {
            CHECK(0, "finish-hook: init failed");
            return;
        }
        ms_context_set_finish_hook((ms_context *)hook_slots[i], hook_fn,
                                   (void *)(uintptr_t)i);
    }

    ms_context_capture(mainc);
    for (i = 0; i < NHOOKS; i++)
        ms_context_switch(mainc, (ms_context *)hook_slots[i]);

    for (i = 0; i < NHOOKS; i++) {
        ok &= (hook_hits[i] == 1);              /* exactly once ... */
        ok &= (hook_got_ud[i] == (uintptr_t)i); /* ... userdata intact */
        ok &= (hargs[i].marker == 100);         /* entry really ran */
        total += hook_hits[i];
    }
    CHECK(ok && total == NHOOKS,
          "finish-hook: fired exactly once per context, userdata intact");

    /* The hook ran BEFORE control returned to the resumer: it fires on
     * the synthetic stack during the trampoline's completion stage. */
    CHECK(hook_hits[0] == 1,
          "finish-hook: completed before resumer regained control");
}

/* ---- 3b. finish-hook REGISTRY semantics (panel SHOULD) ------------------ */

static volatile long g_late_hits;

static void late_hook(void *ud)
{
    (void)ud;
    g_late_hits++;
}

static void test_hook_registry(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static work_arg_t wa;
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;

    g_late_hits = 0;
    poison_tail(c);
    if (ms_context_init(c, p_stack(), USABLE, work_entry, &wa) != 0) {
        CHECK(0, "hook-registry: init failed");
        return;
    }
    ms_context_set_finish_hook(c, late_hook, NULL); /* registered pre-run */
    ms_context_capture(m);
    ms_context_switch(m, c); /* runs to completion; hook fires once */
    CHECK(g_late_hits == 1,
          "hook-registry: completion hook fired exactly once");

    /* A hook registered AFTER the context has FINISHED never fires: the
     * completion stage already ran and runs at most one lifetime. The
     * registry entry just sits inert until destroy or revival. */
    ms_context_set_finish_hook(c, late_hook, NULL);
    usleep(10000); /* no async actor exists; settle window is sufficient */
    CHECK(g_late_hits == 1, "hook-registry: hook-after-FINISH never fires");

    /* Destroy discards any registered hook with the rest of the record
     * (poisoned to DEAD). */
    ms_context_destroy(c);
    CHECK(g_late_hits == 1,
          "hook-registry: destroy discards registered hook");
}

/* ---- 4. re-resume of FINISHED context ---------------------------------- */

static void resume_finished_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static work_arg_t wa;
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;

    poison_tail(c); /* dirty upper state bits must not defeat the guard */
    if (ms_context_init(c, p_stack(), USABLE, work_entry, &wa) != 0)
        _exit(2);
    ms_context_capture(m);
    ms_context_switch(m, c); /* runs to completion => FINISHED */
    ms_context_switch(m, c); /* re-resume FINISHED: brk #0x66 => SIGTRAP */
    _exit(1);                /* silent resume = bug */
}

/* ---- 5. re-resume of RUNNING context (cross-thread misuse) ------------- */

static ms_context *g_run_target;
static volatile long g_go; /* 0 = wait, 1 = misuse thread may fire */

static void run_entry(void *v)
{
    (void)v;
    __atomic_store_n(&g_go, 1, __ATOMIC_SEQ_CST);
    usleep(300000); /* linger RUNNING while the misuse thread fires */
}

static void *misuse_thread(void *v)
{
    static _Alignas(8) unsigned long st_t[NSLOTS];
    (void)v;
    while (!__atomic_load_n(&g_go, __ATOMIC_SEQ_CST))
        ;
    /* Target is RUNNING on another thread: per-record state machine must
     * trap (brk #0x69), never corrupt. */
    ms_context_switch((ms_context *)st_t, g_run_target);
    return NULL;
}

static void resume_running_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    ms_context *m = (ms_context *)st_m;
    pthread_t t;

    g_run_target = (ms_context *)st_c;
    poison_tail(g_run_target);
    if (ms_context_init(g_run_target, p_stack(), USABLE, run_entry,
                        NULL) != 0)
        _exit(2);
    if (pthread_create(&t, NULL, misuse_thread, NULL) != 0)
        _exit(2);
    ms_context_capture(m);
    ms_context_switch(m, g_run_target); /* target becomes RUNNING */
    pthread_join(t, NULL);
    _exit(1); /* misuse thread trapped => we never get here */
}

/* ---- 6. misalignment rejected loudly at make --------------------------- */

static void misalign_child(void)
{
    static _Alignas(8) unsigned long st_c[NSLOTS];
    ms_context *c = (ms_context *)st_c;
    int bad = 0;
    size_t i;

    memset(st_c, 0xA5, sizeof(st_c));
    /* Unaligned stack_low => misaligned stack_top: ms_context_init must
     * reject with -EINVAL, leaving storage untouched — the loud,
     * deterministic front line ahead of the backend's brk #0x64. */
    if (ms_context_init(c, (char *)p_stack() + 8, USABLE, work_entry,
                        NULL) != -EINVAL)
        bad = 1;
    for (i = 0; i < NSLOTS; i++)
        if (st_c[i] != 0xA5A5A5A5A5A5A5A5UL)
            bad = 1;
    _exit(bad ? 1 : 0);
}

/* ------------------------------------------------------------------------ */

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0); /* line-buffered: keep pre-trap rows */
    printf("== s5/ctx lifecycle probe (issue #66)\n");

    test_bulk_live();
    test_threads_pairs();
    test_finish_hook();
    test_hook_registry();

    CHECK(child_result(resume_finished_child, SIGTRAP, 0),
          "re-resume: FINISHED ctx traps (SIGTRAP in child)");
    CHECK(child_result(resume_running_child, SIGTRAP, 0),
          "re-resume: RUNNING ctx traps (SIGTRAP in child)");
    CHECK(child_result(misalign_child, 0, 0),
          "misalign: make rejects unaligned stack (-EINVAL, no crash)");

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}
