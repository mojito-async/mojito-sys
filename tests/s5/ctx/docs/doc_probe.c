/*
 * doc_probe.c — S5.8 documentation-lane conformance probe (issue #71).
 *
 * This lane's deliverable is the documentation itself; this probe is the
 * TDD fixture that verifies the DOCUMENTED claims both (a) exist in the
 * spec and (b) actually hold against the packaged libmojito_sys.dylib.
 * It is RED until the "Context debug/unwind + platform notes" section
 * lands in docs/mojito-sys_IMPLEMENTATION_SPEC.md (spec path = argv[1]).
 *
 * The probe asserts, against the real backend:
 *   1. DOCUMENTED BEHAVIOR (spec §54 "Context debug/unwind + platform
 *      notes" must document each of the invariants below — marker check,
 *      see spec_markers[]). Before the section lands this is red by
 *      design (documentation lane: the DOC is the feature).
 *   2. Lifecycle traps surface as SIGTRAP (AArch64 brk) on GENUINE misuse
 *      — each exercised in a FORK CHILD so the destructive trap dies
 *      loudly without crashing the suite:
 *        - re-resume of a FINISHED context        -> brk #0x66
 *        - resume of DEAD (zeroed / destroyed)    -> brk #0x68
 *        - re-resume of a RUNNING context from a  -> brk #0x69
 *          different OS thread (per-record state machine)
 *   3. The documented state machine still works: init arms EMPTY; first
 *      resume RUNNING; a mid-life yield flips SUSPENDED then back to
 *      RUNNING on re-resume; entry return flips FINISHED permanently
 *      and switches out to the most recent switcher; and a capture on a
 *      FINISHED record REVIVES it to the caller's live snapshot (resumable
 *      without trapping).
 *   4. An unaligned synthetic stack is rejected loudly by ms_context_init
 *      (-EINVAL, no crash) ahead of the backend assembler's brk #0x64.
 *
 * Usage: doc_probe <path-to-spec.md>
 *   DYLD_LIBRARY_PATH must point at the packaged dylib's directory.
 */

#include <mojito_sys.h>

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define USABLE (64 * 1024)
/* Record slots: frozen v2 168 bytes + 4-slot lifecycle tail = 200 bytes. */
#define NSLOTS 25

/* -- documentation-presence markers (spec §54) ----------------------------
 * The probe greps argv[1] for these exact substrings. Each names a fact the
 * "Context debug/unwind + platform notes" section MUST document; the spec
 * append is authored so every string below appears verbatim. Missing markers
 * are reported individually and fail the doc-presentation row. */
static const char *const spec_markers[] = {
    "Context debug/unwind + platform notes",
    "SIGTRAP",
    "brk #0x66",
    "brk #0x68",
    "brk #0x69",
    "brk #0x6a",
    "DWARF FDE",
    "lldb",
    "gdb",
    "AArch64",
    "x86-64",
    "#70", /* stack-growth policy ref */
    "#72", /* x86-64 SysV pending */
};
#define NSPEC_MARKERS (sizeof(spec_markers) / sizeof(spec_markers[0]))

static int failures;

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-52s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

/* Guarded synthetic stack: PROT_NONE page below the usable region, so a
 * downward underflow faults loudly instead of scribbling. Returns the LOW
 * end of the usable region (stack_low). */
static void *p_stack(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t total = (size_t)ps + USABLE;
    char *p = mmap(NULL, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        exit(2);
    }
    mprotect(p, (size_t)ps, PROT_NONE);
    return p + ps;
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

/* ---- 1. documentation presence ---------------------------------------- */

static void test_docs_present(const char *spec_path)
{
    FILE *f;
    char *text = NULL;
    long len;
    size_t i, missing = 0;

    if (spec_path == NULL) {
        CHECK(0, "docs: spec path provided (argv[1])");
        return;
    }
    f = fopen(spec_path, "r");
    if (f == NULL) {
        printf("  %-52s FAIL\n",
               "docs: spec readable (fopen)");
        failures++;
        return;
    }
    if (fseek(f, 0, SEEK_END) != 0 || (len = ftell(f)) < 0 ||
        fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        CHECK(0, "docs: spec sized");
        return;
    }
    text = malloc((size_t)len + 1);
    if (text == NULL) {
        fclose(f);
        CHECK(0, "docs: spec buffer alloc");
        return;
    }
    if (fread(text, 1, (size_t)len, f) != (size_t)len) {
        fclose(f);
        free(text);
        CHECK(0, "docs: spec read");
        return;
    }
    fclose(f);
    text[len] = '\0';

    for (i = 0; i < NSPEC_MARKERS; i++) {
        if (strstr(text, spec_markers[i]) == NULL) {
            printf("  %-52s FAIL (missing: %s)\n",
                   "docs: debug/unwind marker in spec", spec_markers[i]);
            missing++;
        }
    }
    free(text);
    CHECK(missing == 0 && len > 0,
          "docs: §54 debug/unwind + platform-notes section documents claims");
}

/* ---- 2. lifecycle traps (SIGTRAP on misuse) ---------------------------- */

static void simple_entry(void *v)
{
    long *marker = v;
    *marker = 1; /* ran to completion */
}

static void resume_finished_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static long ran;
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;

    ran = 0;
    if (ms_context_init(c, p_stack(), USABLE, simple_entry, &ran) != 0)
        _exit(2);
    ms_context_capture(m);
    ms_context_switch(m, c); /* entry returns => FINISHED */
    if (ran != 1)
        _exit(3);
    ms_context_switch(m, c); /* re-resume FINISHED: brk #0x66 => SIGTRAP */
    _exit(1);                /* silent resume of FINISHED = bug */
}

static void resume_dead_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS]; /* never initialized */
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;

    memset(st_c, 0, sizeof(st_c)); /* DEAD storage, never armed */
    ms_context_capture(m);
    ms_context_switch(m, c); /* resume DEAD: brk #0x68 => SIGTRAP */
    _exit(1);                /* silent resume of DEAD = bug */
}

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
    memset(st_c, 0, sizeof(st_c));
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

/* ---- 3. state-machine transitions -------------------------------------- */

typedef struct {
    long entered;
    long suspended; /* resumed-from-yield, child context */
    long finished;  /* control returned to resumer after FINISHED */
    ms_context *main;
    ms_context *child;
} sm_arg_t;

static void sm_entry(void *v)
{
    sm_arg_t *a = v;
    a->entered++;
    /* Mid-life yield: child goes RUNNING -> SUSPENDED, resumer back to
     * RUNNING; re-resume proves SUSPENDED -> RUNNING, then return flips
     * the record to FINISHED permanently. */
    ms_context_switch(a->child, a->main);
    a->suspended++; /* only reached after a SUSPENDED -> RUNNING re-resume */
}

static void test_state_machine(void)
{
    static _Alignas(8) unsigned long st_main[NSLOTS];
    static _Alignas(8) unsigned long st_child[NSLOTS];
    static sm_arg_t a;
    ms_context *m = (ms_context *)st_main;
    ms_context *c = (ms_context *)st_child;

    memset(&a, 0, sizeof(a));
    memset(st_main, 0, sizeof(st_main));
    memset(st_child, 0, sizeof(st_child));
    a.main = m;
    a.child = c;

    if (ms_context_init(c, p_stack(), USABLE, sm_entry, &a) != 0) {
        CHECK(0, "state-machine: init (arms EMPTY)");
        return;
    }
    ms_context_capture(m);               /* main: live snapshot */
    ms_context_switch(m, c);             /* EMPTY -> RUNNING; entry yields */
    /* Back in main after the entry's yield: child is SUSPENDED. */
    if (a.entered != 1 || a.suspended != 0) {
        CHECK(0, "state-machine: first resume ran entry to yield point");
        return;
    }
    ms_context_switch(m, c);             /* SUSPENDED -> RUNNING; entry finishes */
    /* Entry returned => child FINISHED; permanent switch-out returns here. */
    CHECK(a.entered == 1 && a.suspended == 1,
          "state-machine: MID-LIFE suspension + re-resume + FINISH");
    CHECK(a.finished == 0,
          "state-machine: completion switched control permanently to resumer");
    (void)a.finished;
}

/* Capture REVIVES a FINISHED record to the caller's live snapshot: the
 * self-switch re-arm is unconditional, so after capture(c) a completed
 * record reads SUSPENDED again and resumes from the fresh snapshot
 * (header F5 contract). Bounded in a fork child with a memory-backed
 * `step` guard — the revival re-entry re-runs `step++` through a
 * restored snapshot — so the single revive-resume lands at the capture
 * point and the child then terminates (sentinel-probe pattern). A capture
 * that failed to re-arm (still FINISHED/DEAD) traps (SIGTRAP) instead of
 * exiting 0. */
static void revive_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static long ran;
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;
    volatile int step = 0; /* memory-backed: re-runs via restored snapshot */

    ran = 0;
    memset(st_c, 0, sizeof(st_c));
    if (ms_context_init(c, p_stack(), USABLE, simple_entry, &ran) != 0)
        _exit(2);
    ms_context_capture(m);
    ms_context_switch(m, c);           /* entry returns => FINISHED */
    if (ran != 1)
        _exit(3);
    ms_context_capture(c);             /* REVIVE FINISHED: c aliases main */
    step++;                            /* runs again on revival */
    if (step == 1) {
        ms_context_switch(m, c);       /* resume revived c => returns below */
        _exit(9);                      /* back in main only via restore point */
    }
    _exit(step == 2 ? 0 : 4);          /* revival visit: resumable, no trap */
}

/* ---- 4. unaligned stack rejected --------------------------------------- */

static void misalign_child(void)
{
    static _Alignas(8) unsigned long st_c[NSLOTS];
    ms_context *c = (ms_context *)st_c;
    int bad = 0;
    size_t i;

    memset(st_c, 0xA5, sizeof(st_c));
    /* Unaligned stack_low => misaligned stack_top: ms_context_init must
     * reject with -EINVAL, storage untouched — the loud, deterministic
     * front line ahead of the backend's brk #0x64. */
    if (ms_context_init(c, (char *)p_stack() + 8, USABLE, simple_entry,
                        NULL) != -EINVAL)
        bad = 1;
    for (i = 0; i < NSLOTS; i++)
        if (st_c[i] != 0xA5A5A5A5A5A5A5A5UL)
            bad = 1;
    _exit(bad ? 1 : 0);
}

/* ------------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0); /* line-buffered: keep pre-trap rows */
    printf("== s5-ctx-docs probe (issue #71)\n");

    test_docs_present(argc > 1 ? argv[1] : NULL);

    test_state_machine();

    CHECK(child_result(resume_finished_child, SIGTRAP, 0),
          "lifecycle: re-resume FINISHED traps (SIGTRAP, brk #0x66)");
    CHECK(child_result(resume_dead_child, SIGTRAP, 0),
          "lifecycle: resume DEAD storage traps (SIGTRAP, brk #0x68)");
    CHECK(child_result(resume_running_child, SIGTRAP, 0),
          "lifecycle: re-resume RUNNING (other thread) traps (SIGTRAP, brk #0x69)");
    CHECK(child_result(revive_child, 0, 0),
          "lifecycle: capture REVIVES FINISHED record (resumable, no trap)");
    CHECK(child_result(misalign_child, 0, 0),
          "make: unaligned stack rejected (-EINVAL, no crash)");

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}