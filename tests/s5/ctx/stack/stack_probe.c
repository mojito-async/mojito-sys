/*
 * stack_probe.c — S5.7 acceptance net (#70): the STACK GROWTH POLICY within
 * a reservation. Links against the PACKAGED libmojito_sys.dylib and drives
 * only the public s5-ctx ABI + the public stack-reservation ABI
 * (mjs_stack_alloc).
 *
 * POLICY (5-expert panel ruling, recorded in the spec append + the s5-ctx
 * header block): NativeContext stacks are FIXED-reservation, NO automatic
 * software growth. The enclosing reservation is created by its OWNER via
 * mjs_stack_alloc, which paints a PROT_NONE hardware guard page at the LOW
 * (floor) end of the reservation. Growth is top-down over the committed
 * range within the fixed reservation; overflow PAST the floor faults
 * SYNCHRONOUSLY at the faulting store (loud, contained, non-moving —
 * ADR-SYS-005 + SYS-4 + SYS-7). There is NO per-switch software
 * sp-vs-floor check (it cannot prevent the faulting write and would tax
 * every switch); the guard page is the enforcement point.
 *
 * Tests (at BOTH -O0 and -O2, see run.sh):
 *   T1  CONTAINED GROWTH: a context on an mjs_stack_alloc reservation runs
 *       a deep call chain WELL INSIDE the reservation and completes — real
 *       top-down growth within the fixed reservation is never throttled.
 *   T2  GUARD CROSSING: forked child writing into the reservation's floor
 *       dies SIGBUS|SIGSEGV (synchronous fault at the guard — same
 *       acceptance as the s1 memory-stack guard probe).
 *   T3  CANARY (no silent neighbor corruption): a manual
 *       [RW canary 0xA5][PROT_NONE guard 1p][RW usable] layout. Overflowing
 *       child is killed at the guard; the parent memcmps the canary
 *       byte-for-byte — bytes below the guard are never scribbled.
 *   T4  RED-DELTA (stack_top wrap): ms_context_init with a 16-aligned
 *       stack_low near SIZE_MAX (stack_low + stack_size wraps) MUST return
 *       -EINVAL with ctx untouched — mjs__ctx_make_raw never sees a wrapped
 *       stack_top (wrap guard: s5/x86 10a3607, pulled into this lane).
 *   T5  FROZEN SURFACE ANCHORS: ms_context_size() == 200 (168 v2 + 32
 *       tail); caller storage BEYOND 200 is never touched by init; and an
 *       UNGUARDED static 16-aligned buffer still inits and runs to
 *       completion (documented-UB class — overflow on an unguarded buffer
 *       is the CALLER's error — stays testable and working).
 *   MISALIGN  hardened restore: a context whose SAVED sp (slot @160) is
 *       forged to a 16-MISALIGNED value is rejected LOUDLY (SIGTRAP in a
 *       forked child) at the next switch/restore — the backend traps
 *       BEFORE the garbage sp goes live (new committed brk, distinct from
 *       the #0x68 dead-resume trap).
 *
 * Build & run via tests/s5/ctx/stack/run.sh.
 */

#include <mojito_sys.h>

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define SAFE_HEADROOM (8 * 1024)   /* deep_to_floor stop headroom */
#define FLOOR_MARGIN 4096   /* stop recursing this far above the guard floor */
#define CANARY_BYTES 4096
#define DEEP_FLOOR 8        /* adaptive depth must exceed this many frames */
#define COMMIT_64K (64 * 1024)
#define RESERVE_256K (256 * 1024)
/* Record slots: frozen v2 168 bytes + 4-slot lifecycle tail = 200. */
#define NSLOTS 25
#define SP_OFF 160
#define REC_END 200

static int failures;
static size_t PAGE; /* host page size; stack ABI guard must be page mult. */

static void page_size_init(void)
{
    long ps = sysconf(_SC_PAGESIZE);
    PAGE = ps > 0 ? (size_t)ps : 4096;
}

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-58s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

/* A 16-aligned static slab usable as an unguarded context stack base. */
static unsigned char g_plain[COMMIT_64K] __attribute__((aligned(16)));

/* ---- fork harness ------------------------------------------------ */

static int child_expect_signal(void (*fn)(void), int want_signal)
{
    pid_t pid;
    int st;

    fflush(stdout);
    pid = fork();
    if (pid < 0) { perror("fork"); return 0; }
    if (pid == 0) {
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        signal(SIGTRAP, SIG_DFL);
        fn();
        _exit(0); /* surviving a should-trap child = silent bug */
    }
    if (waitpid(pid, &st, 0) < 0) { perror("waitpid"); return 0; }
    return WIFSIGNALED(st) && WTERMSIG(st) == want_signal && !WIFEXITED(st);
}

static int child_clean_exit(void (*fn)(void))
{
    pid_t pid;
    int st;

    fflush(stdout);
    pid = fork();
    if (pid < 0) { perror("fork"); return 0; }
    if (pid == 0) {
        fn();
        _exit(0);
    }
    if (waitpid(pid, &st, 0) < 0) { perror("waitpid"); return 0; }
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}

static int child_bus_or_segv(void (*fn)(void))
{
    pid_t pid;
    int st;

    fflush(stdout);
    pid = fork();
    if (pid < 0) { perror("fork"); return 0; }
    if (pid == 0) {
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        fn();
        _exit(0);
    }
    if (waitpid(pid, &st, 0) < 0) { perror("waitpid"); return 0; }
    return WIFSIGNALED(st) &&
           (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV);
}


static void work_entry(void *v)
{
    long *marker = v;
    *marker += 100;
}

/* ---- T1: contained growth on an mjs_stack_alloc reservation ---------- */

typedef struct {
    long got;
    long expect;
    ms_context *self;
    ms_context *sched;
    uintptr_t floor;   /* committed-span floor (top - COMMIT) */
} grow_arg_t;

/* Adaptive legal descent: recurses until accumulated alloca depth
 * reaches the committed-span budget. Each frame allocates
 * ALLOCA_STEP bytes via alloca() through a volatile sink (escapes, so
 * the compiler cannot elide it) and recurse — at -O0 AND -O2 the real
 * sp moves by ALLOCA_STEP each frame, so depth growth is observable and
 * deterministic. Termination is a byte-budget against floor_headroom:
 * the frame chain has grown COMMIT_64K - SAFE_HEADROOM bytes before
 * stopping, i.e. the deepest live sp stays >= floor + SAFE_HEADROOM.
 * This avoids __builtin_frame_address and register-sp reads, both of
 * which clang -O2 folds to constants (observed spin at deep_to_floor
 * with zero frame growth). Depth is a result, never a fixed count. */
#define ALLOCA_STEP 512
static __attribute__((noinline)) long deep_to_floor_impl(size_t budget)
{
    volatile char *sink;
    if (budget < ALLOCA_STEP)
        return 0;
    sink = (volatile char *)__builtin_alloca(ALLOCA_STEP);
    sink[0] = (char)budget;      /* write through the volatile pointer */
    return 1 + deep_to_floor_impl(budget - ALLOCA_STEP);
}

static long deep_to_floor(uintptr_t floor)
{
    (void)floor;
    size_t budget = COMMIT_64K - SAFE_HEADROOM;
    return deep_to_floor_impl(budget);
}
static void grow_entry(void *v)
{
    grow_arg_t *a = v;
    a->got = deep_to_floor(a->floor);
    ms_context_switch(a->self, a->sched); /* bounce; then return=>FINISHED */
}

static void test_contained_growth(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static grow_arg_t ga;
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;
    void *base = NULL, *guard_low = NULL;
    size_t top = 0;

    if (mjs_stack_alloc(RESERVE_256K, COMMIT_64K, PAGE,
                        &base, &guard_low, &top) != 0 ||
        guard_low == NULL || top <= (uintptr_t)guard_low) {
        CHECK(0, "T1: mjs_stack_alloc failed");
        return;
    }
    ga.got = 0;
    ga.self = c;
    ga.sched = m;
    ga.floor = (uintptr_t)top - COMMIT_64K; /* only the committed top span is RW */
    if (ms_context_init(c, guard_low, top - (uintptr_t)guard_low,
                        grow_entry, &ga) != 0) {
        mjs_stack_free(&base);
        CHECK(0, "T1: init failed");
        return;
    }
    ms_context_capture(m);
    ms_context_switch(m, c); /* adaptive deep chain runs inside reservation */
    ms_context_switch(m, c); /* resume once more to let it finish */
    mjs_stack_free(&base);
    CHECK(ga.got > DEEP_FLOOR,
          "T1: deep growth within committed top span completes (no false ceiling)");
}

/* ---- T2: guard crossing dies loudly -------------------------------- */

static void guard_crossing_child(void)
{
    void *base = NULL, *guard_low = NULL;
    size_t top = 0, guard_bytes = 0;

    if (mjs_stack_alloc(RESERVE_256K, COMMIT_64K, PAGE,
                        &base, &guard_low, &top) != 0)
        _exit(4);
    guard_bytes = (size_t)((uintptr_t)guard_low - (uintptr_t)base);
    volatile char *guard = (volatile char *)(uintptr_t)base + guard_bytes / 2;
    *guard = 7; /* must fault (PROT_NONE guard) */
    _exit(0);   /* reached => guard writable (silent corruption) */
}

static void test_guard_crossing(void)
{
    CHECK(child_bus_or_segv(guard_crossing_child),
          "T2: guard crossing dies SIGBUS|SIGSEGV (loud at boundary)");
}

/* ---- T3: canary ------------------------------------------------ */

static char *g_layout;
static size_t g_usable;

static void build_canary_layout(size_t usable)
{
    size_t canary = CANARY_BYTES, guard = PAGE, total = canary + guard + usable;
    char *p = mmap(NULL, total, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    memset(p, 0xA5, canary);
    mprotect(p + canary, guard, PROT_NONE);
    memset(p + canary + guard, 0, usable);
    g_layout = p;
    g_usable = usable;
}

static void overflow_child(void)
{
    size_t canary = CANARY_BYTES, guard = PAGE;
    char *usable = g_layout + canary + guard;
    size_t i;
    for (i = 0; i < g_usable + guard + canary * 2; i += 4096)
        usable[i] = (char)0xEE; /* must fault at guard before touching canary */
}

static void test_canary(void)
{
    size_t canary = CANARY_BYTES, guard = PAGE;
    unsigned char snapshot[CANARY_BYTES];
    int killed, same;
    size_t i;

    build_canary_layout(COMMIT_64K);
    memcpy(snapshot, g_layout, canary);

    killed = child_bus_or_segv(overflow_child);
    CHECK(killed,
          "T3: overflow crossing guard killed in child (SIGBUS|SIGSEGV)");

    same = memcmp(g_layout, snapshot, canary) == 0;
    for (i = 0; i < canary; i++)
        same &= (g_layout[i] == (char)0xA5);
    CHECK(same,
          "T3: canary below guard byte-identical (no neighbor corruption)");

    munmap(g_layout, canary + guard + g_usable);
}

/* ---- T4: stack_top wrap rejected with -EINVAL -------------------- */

static void wrap_child(void)
{
    static _Alignas(8) unsigned long st_c[NSLOTS];
    size_t i;
    int bad = 0;
    uintptr_t low = (((uintptr_t)~0ULL) - 256 + 32) & ~(uintptr_t)15u;
    long marker = 0;

    memset(st_c, 0xA5, sizeof(st_c));
    /* entry non-NULL so ONLY the wrap factor is under test. low is high and
     * 16-aligned; low + 256 wraps around to a wild low address. */
    if (ms_context_init((ms_context *)st_c, (void *)low, 256, work_entry,
                        &marker) != -EINVAL)
        bad = 1;
    for (i = 0; i < NSLOTS; i++)
        if (st_c[i] != 0xA5A5A5A5A5A5A5A5UL)
            bad = 1;
    _exit(bad ? 1 : 0);
}

/* ---- T5: frozen-surface anchors --------------------------------- */

static void test_frozen_surface(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_big[NSLOTS + 16]; /* 280 bytes */
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_big;
    long marker = 0;
    int ok = 1;
    size_t i;

    CHECK(ms_context_size() == REC_END,
          "T5: ms_context_size() == 200 (168 v2 + 32 tail)");
    CHECK(ms_context_alignment() == sizeof(void *),
          "T5: ms_context_alignment() == pointer width");
    /* Tail offsets: init zeroes ret_to/finish_cb/finish_ud and writes
     * state=EMPTY at the documented v3 tail offsets 168/176/184/192. */
    memset(st_big, 0x00, sizeof(st_big));
    if (ms_context_init(c, g_plain, sizeof(g_plain), work_entry,
                        &marker) != 0) {
        CHECK(0, "T5: tail-offset init failed");
        return;
    }
    ok = ((unsigned long *)c)[168 / 8] == 1 &&   /* state == EMPTY */
         ((unsigned long *)c)[176 / 8] == 0 &&   /* ret_to == NULL */
         ((unsigned long *)c)[184 / 8] == 0 &&   /* finish_cb == NULL */
         ((unsigned long *)c)[192 / 8] == 0;     /* finish_ud == NULL */
    CHECK(ok, "T5: v3 tail offsets 168/176/184/192 populated by init");

    /* Caller storage beyond 200 must never be touched by init. */
    memset(st_big, 0x00, sizeof(st_big));
    memset((unsigned char *)st_big + REC_END, 0xCC, sizeof(st_big) - REC_END);
    if (ms_context_init(c, g_plain, sizeof(g_plain), work_entry,
                        &marker) != 0) {
        CHECK(0, "T5: unguarded static buffer init");
        return;
    }
    for (i = REC_END; i < sizeof(st_big); i++)
        if (((unsigned char *)st_big)[i] != 0xCC)
            ok = 0;
    CHECK(ok, "T5: caller storage beyond 200 untouched (footprint 200)");

    /* Unguarded static buffer (documented-UB class) inits and runs. */
    ms_context_capture(m);
    ms_context_switch(m, c);
    CHECK(marker == 100,
          "T5: unguarded static buffer inits and runs to completion");
}

/* ---- MISALIGN: forged 16-misaligned saved sp rejected loudly ------ */

static void never_entry(void *v)
{
    (void)v; /* must never run: restore must trap first */
}

static void misalign_child(void)
{
    static _Alignas(8) unsigned long st_m[NSLOTS];
    static _Alignas(8) unsigned long st_c[NSLOTS];
    static unsigned char stack_buf[64 * 1024] __attribute__((aligned(16)));
    ms_context *m = (ms_context *)st_m;
    ms_context *c = (ms_context *)st_c;
    uintptr_t stack_top = (uintptr_t)stack_buf + sizeof(stack_buf);

    if (ms_context_init(c, stack_buf, sizeof(stack_buf), never_entry,
                        NULL) != 0)
        _exit(2);
    /* Forge the saved sp (slot @160) to a 16-MISALIGNED value: bit 3 set
     * => value % 16 == 8 => not 16-aligned. Restore must trap BEFORE the
     * garbage sp goes live. */
    ((unsigned long *)c)[SP_OFF / 8] = stack_top + 8;
    ms_context_capture(m);
    ms_context_switch(m, c); /* must trap (SIGTRAP) */
    _exit(1);                /* silent restore = bug */
}

/* ------------------------------------------------------------------- */

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("== s5/ctx stack-growth policy probe (issue #70)\n");
    page_size_init();

    test_contained_growth();
    test_guard_crossing();
    test_canary();
    CHECK(child_clean_exit(wrap_child),
          "T4: stack_top wrap rejected -EINVAL, ctx untouched");
    test_frozen_surface();
    CHECK(child_expect_signal(misalign_child, SIGTRAP),
          "MISALIGN: forged 16-misaligned sp traps (SIGTRAP in child)");

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}
