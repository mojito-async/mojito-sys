/*
 * oracle_probe.c — identical sentinel workload executed against EITHER
 * backend dylib, with stdout kept byte-identical across backends
 * (issue #65 oracle cross-check): run.sh runs this binary against the
 * production libmojito_sys.dylib and the spike libmojito_spike.dylib and
 * diffs the two outputs. Divergence means the productionized backend
 * drifted from the panel-proven spike at the register level.
 *
 * Backend selection happens at runtime via dlopen/dlsym:
 *   libmojito_sys.dylib   -> ms_context_init / ms_context_switch
 *   libmojito_spike.dylib -> ms_ctx_make / ms_ctx_switch
 * capture semantics (driver snapshot) use switch(ctx, ctx), which is what
 * ms_context_capture does on the prod side and works identically on the
 * spike (which has no capture primitive).
 *
 * The worker asm invokes the switch primitive through a function pointer
 * stored in the worker argument at +64, so one binary serves both ABIs.
 *
 * Everything printed to stdout is deterministic and backend-independent;
 * the backend label goes to stderr only.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define USABLE (64 * 1024)
/* Save-area slots sized for BOTH oracle targets: prod (v3, 200 bytes
 * since #66) and spike (v2, 168 bytes) — the spike library touches only
 * its own 168-byte prefix. */
#define NSLOTS 25

static int failures;

#define CHECK(cond, name)                                          \
    do {                                                           \
        int ok_ = (cond);                                          \
        printf("  %-52s %s\n", name, ok_ ? "OK" : "FAIL");         \
        if (!ok_)                                                  \
            failures++;                                            \
    } while (0)

typedef void (*switch_fn)(void *, void *);
typedef void (*make_fn)(void *, void *, void (*)(void *), void *);
typedef int (*init_fn)(void *, void *, size_t, void (*)(void *), void *);

typedef struct {
    long counter;          /* +0  */
    long left;             /* +8  */
    long regs_ok;          /* +16 */
    long sp_ok;            /* +24 */
    unsigned long tag;     /* +32 */
    void *self;            /* +40 */
    void *peer;            /* +48 */
    void *sched;           /* +56 */
    switch_fn sw;          /* +64: backend switch, called via blr in asm */
} o_arg_t;

static switch_fn sw_fn;
static init_fn init_prod;
static make_fn make_spike;

static o_arg_t oa = { 0, 2, 1, 1, 0x33333000UL, NULL, NULL, NULL, NULL };
static o_arg_t ob = { 0, 2, 1, 1, 0x44444000UL, NULL, NULL, NULL, NULL };

/* Tag-fill / verify / worker, verbatim-in-structure from the committed
 * sentinel probe: x19..x28 <- tag+{0x000..0x900}; d8..d15 mirror x19..x26. */
__asm__(
".text\n"
".align 4\n"

".private_extern _o_fill\n"
"_o_fill:\n"
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
".private_extern _o_check\n"
"_o_check:\n"
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

/* Worker body shared by both probe entries; arg offsets in comments.
 * Rounds: ping-pong `left` times to the peer through the BACKEND SWITCH
 * POINTER (+64), verify, yield once to the scheduler context, then
 * RETURN — exercising the real exit trampoline. */
".private_extern _oworker\n"
"_oworker:\n"                                  /* x0 = o_arg_t *arg        */
"       stp     x29, x30, [sp, #-32]!\n"
"       mov     x29, sp\n"
"       str     x0, [sp, #16]\n"               /* arg on our own frame     */
"       ldr     x0, [x0, #32]\n"               /* tag                      */
"       bl      _o_fill\n"                     /* tags x19-x28, d8-d15     */
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
"       ldr     x9, [x8, #64]\n"               /* sw_fn                    */
"       blr     x9\n"
"       b       2b\n"                          /* resumed here             */
"3:\n"
"       ldr     x8, [sp, #16]\n"
"       ldr     x0, [x8, #32]\n"               /* tag                      */
"       ldr     x1, [x8, #16]\n"               /* &regs_ok                 */
"       bl      _o_check\n"                    /* x19-x28+d8-d15 intact?   */
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
"       ldr     x9, [x8, #64]\n"               /* sw_fn                    */
"       blr     x9\n"                          /* mid-life yield           */
"       ldp     x29, x30, [sp], #32\n"
"       ret\n"                                 /* exit via trampoline      */

"\n.private_extern _oa_entry\n"
"_oa_entry:\n"                                 /* x0 = &oa                 */
"       b       _oworker\n"
"\n.private_extern _ob_entry\n"
"_ob_entry:\n"                                 /* x0 = &ob                 */
"       b       _oworker\n"
);

void oa_entry(void *);
void ob_entry(void *);

/* Guarded synthetic stack: PROT_NONE page below the usable region.
 * Returns the LOW end of the usable region (stack_low). */
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

/* Backend-agnostic init: prod takes (stack_low, size) with validation;
 * spike takes stack_top and no validation. */
static int oracle_init(void *ctx, void (*entry)(void *), void *ud)
{
    if (init_prod)
        return init_prod(ctx, p_stack(), USABLE, entry, ud);
    make_spike(ctx, p_stack() + USABLE, entry, ud);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <dylib>\n", argv[0]);
        return 2;
    }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (h == NULL) {
        fprintf(stderr, "dlopen(%s): %s\n", argv[1], dlerror());
        return 2;
    }
    init_prod = (init_fn)dlsym(h, "ms_context_init");
    const char *sw_name = init_prod ? "ms_context_switch" : "ms_ctx_switch";
    sw_fn = (switch_fn)dlsym(h, sw_name);
    if (sw_fn == NULL) {
        fprintf(stderr, "%s: %s not found\n", argv[1], sw_name);
        return 2;
    }
    if (init_prod == NULL) {
        make_spike = (make_fn)dlsym(h, "ms_ctx_make");
        if (make_spike == NULL) {
            fprintf(stderr, "%s: ms_ctx_make not found\n", argv[1]);
            return 2;
        }
    }
    fprintf(stderr, "== ctx oracle probe vs %s (%s backend)\n",
            argv[1], init_prod ? "prod" : "spike");

    static _Alignas(8) unsigned long st_main[NSLOTS];
    static _Alignas(8) unsigned long st_a[NSLOTS];
    static _Alignas(8) unsigned long st_b[NSLOTS];

    oa.self = st_a; oa.peer = st_b; oa.sched = st_main; oa.sw = sw_fn;
    ob.self = st_b; ob.peer = st_a; ob.sched = st_main; ob.sw = sw_fn;

    if (oracle_init(st_a, oa_entry, &oa) != 0 ||
        oracle_init(st_b, ob_entry, &ob) != 0) {
        printf("init FAILED\n");
        return 1;
    }

    sw_fn(st_main, st_main);       /* driver snapshot (capture semantics) */
    sw_fn(st_main, st_a);
    /* Back after A's mid-life yield: A and B have ping-ponged once each
     * and A verified itself. Driver state must be intact. */
    CHECK(oa.counter == 2 && ob.counter >= 1,
          "workers progressed across real switches");

    sw_fn(st_main, st_a);          /* A resumes post-yield, exits */
    CHECK(oa.regs_ok == 1 && oa.sp_ok == 1 && oa.counter == 2,
          "A: x19-x28 + d8-d15 preserved, sp aligned, exited cleanly");

    sw_fn(st_main, st_b);          /* B resumes post-ping, verifies, yields */
    CHECK(ob.regs_ok == 1 && ob.sp_ok == 1 && ob.counter == 2,
          "B: x19-x28 + d8-d15 preserved, sp aligned");

    sw_fn(st_main, st_b);          /* B resumes post-yield, exits */
    CHECK(ob.counter == 2,
          "B: exited cleanly through the trampoline");

    printf("RESULT: %s\n", failures ? "FAILED" : "all green");
    return failures ? 1 : 0;
}
