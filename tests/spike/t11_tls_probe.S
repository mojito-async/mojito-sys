/*
 * t11_tls_probe.S — S0/M1.4-T11 probe: OS-thread TLS continuity across
 * context switches (aarch64, macOS arm64, Mach-O). RE-POINTED (#128) at
 * the PRODUCTION native/posix/ms_context_aarch64.S `ms_context_switch`/
 * `ms_context_init`, called directly (statically linked, no dlsym
 * indirection -- see t8_gpr_probe.S's header for the full account). The
 * pthread TSD calls (`pthread_key_create`/`pthread_setspecific`/
 * `pthread_getspecific`/`pthread_self`) are also linked directly now
 * (`.extern`, resolved against libSystem at link time) instead of being
 * dlsym'd -- they were never spike symbols in the first place, so there
 * was never a reason to resolve them at runtime; the S0-era version only
 * did so because it dlsym'd everything uniformly alongside the (then
 * genuinely runtime-resolved) spike symbols.
 *
 * A context switch on ONE OS thread must not disturb thread-local state.
 * This probe verifies the spec invariant FUNCTIONALLY through the pthread
 * TSD API (the consumer-visible TLS contract):
 *
 *   1. Scheduler seeds a TSD key with magic M1 before entering the
 *      synthetic context.
 *   2. Inside the synthetic context, pthread_getspecific(key) MUST return
 *      M1, and pthread_self() must be unchanged.
 *   3. After switching back, pthread_getspecific(key) MUST still return M1.
 *
 * Raw TLS-pointer register reads (TPIDR_EL0) are captured and exposed via
 * getters for information only -- on macOS arm64 libSystem may legitimately
 * rewrite TPIDR_EL0, so register equality is NOT gated on.
 *
 * Exported:
 *   Int   t11_run(Int stack_low, Int stack_top) verdict bitmask; 0 = TLS
 *                                                fully continuous
 *   Int   t11_tpidr_pre(void)  informational: TPIDR_EL0 before the run
 *   Int   t11_tpidr_in(void)   informational: TPIDR_EL0 inside B
 *   Int   t11_tpidr_post(void) informational: TPIDR_EL0 after the run
 *
 * Bit map returned by t11_run:
 *   0   TSD value inside synthetic context != seeded magic M1
 *   1   TSD value after switching back != M1
 *   2   pthread_self inside synthetic context != pre-switch value
 *   3   sp not 16-byte aligned at trampoline->entry handoff
 */

.data
.align 3
g_key:        .quad 0                    /* pthread_key_t */
g_tpidr_pre:  .quad 0                    /* informational */
g_tpidr_in:   .quad 0                    /* informational */
g_tpidr_post: .quad 0                    /* informational */
/* shared block handed to the synthetic context (malloc'd by t11_run):
 *   +0    main ctx save area (224 reserved)
 *   +224  b ctx save area
 *   +448  mask / alignment seed
 *   +456  pthread_self captured by scheduler before entering
 */
g_shared:     .quad 0

.macro LOADM1 r                            /* 0x7E5711CE: seeded magic */
    movz \r, #0x11CE
    movk \r, #0x7E57, lsl #16
.endm

.text
.align 2

/* helper: GETSPEC -> x0 (clobbers x15, x16) */
Lt11_get:
    adrp x16, g_key@PAGE
    ldr  x0, [x16, g_key@PAGEOFF]
    b    _pthread_getspecific

/* helper: SETSPEC(value in x0) — pthread_setspecific(key, value):
 * key goes in x0, VALUE goes in x1. Clobbers x1, x2, x16. */
Lt11_set:
    mov  x2, x0                          /* preserve requested value */
    adrp x16, g_key@PAGE
    ldr  x0, [x16, g_key@PAGEOFF]        /* arg0: key */
    mov  x1, x2                          /* arg1: value */
    b    _pthread_setspecific

/* Int t11_run(Int stack_low [x0], Int stack_top [x1]) -> verdict bitmask
 * (0 = TLS fully continuous). Shared pointer parked in x19 across switches
 * (legitimate reliance on GPR callee-savedness — exercised exhaustively by
 * T8; T11 poisons nothing, so x19 is safe to keep here throughout). */
.globl _t11_run
.extern _malloc
.extern _free
.extern _ms_context_init
.extern _ms_context_switch
.extern _pthread_key_create
.extern _pthread_setspecific
.extern _pthread_getspecific
.extern _pthread_self
.align 2
_t11_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* stack_low */
    mov x22, x1                          /* stack_top */

    /* create the TSD key: pthread_key_create(&g_key, NULL) */
    adrp x0, g_key@PAGE
    add  x0, x0, g_key@PAGEOFF
    mov  x1, #0                          /* no destructor */
    bl   _pthread_key_create
    cbnz w0, Lt11_run_fail

    mov x0, #512
    bl  _malloc
    cbz x0, Lt11_run_fail
    mov x19, x0                          /* shared */

    /* informational: TPIDR_EL0 before the run */
    .inst 0xd53bd040                     /* mrs x0, TPIDR_EL0 */
    adrp x9, g_tpidr_pre@PAGE
    str x0, [x9, g_tpidr_pre@PAGEOFF]

    /* seed TSD with M1 and capture thread identity */
    LOADM1 x0
    bl  Lt11_set
    LOADM1 x0
    bl  Lt11_set                        /* re-seed to be sure */
    bl  _pthread_self
    str x0, [x19, #456]
    str xzr, [x19, #448]

    /* self-capture main ctx (v3 lifecycle) */
    mov x0, x19
    mov x1, x19
    bl  _ms_context_switch

    /* ms_context_init(shared+224, stack_low, stack_size, t11_entry, shared) */
    add x0, x19, #224
    mov x1, x20
    sub x2, x22, x20
    adrp x3, _t11_entry@PAGE
    add  x3, x3, _t11_entry@PAGEOFF
    mov x4, x19
    bl  _ms_context_init

    /* enter B; B yields once; its final switch lands here */
    mov x0, x19                          /* from = main ctx */
    add x1, x19, #224                    /* to   = b ctx    */
    bl  _ms_context_switch

    /* ---- back on the scheduler: post-switch re-verify -> bit 1 ---- */
    bl  Lt11_get
    LOADM1 x9
    cmp x0, x9
    cset x10, ne
    ldr x11, [x19, #448]
    orr x11, x11, x10
    str x11, [x19, #448]

    /* informational: TPIDR_EL0 after the run */
    .inst 0xd53bd040                     /* mrs x0, TPIDR_EL0 */
    adrp x9, g_tpidr_post@PAGE
    str x0, [x9, g_tpidr_post@PAGEOFF]

    ldr x21, [x19, #448]
    mov x0, x19
    bl  _free
    mov x0, x21

    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

Lt11_run_fail:
    mov x0, #-1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/* informational getters */
.globl _t11_tpidr_pre
_t11_tpidr_pre:
    adrp x8, g_tpidr_pre@PAGE
    ldr x0, [x8, g_tpidr_pre@PAGEOFF]
    ret
.globl _t11_tpidr_in
_t11_tpidr_in:
    adrp x8, g_tpidr_in@PAGE
    ldr x0, [x8, g_tpidr_in@PAGEOFF]
    ret
.globl _t11_tpidr_post
_t11_tpidr_post:
    adrp x8, g_tpidr_post@PAGE
    ldr x0, [x8, g_tpidr_post@PAGEOFF]
    ret

/*
 * B-side entry. x0 = shared pointer, parked in x19.
 */
.globl _t11_entry
.align 2
_t11_entry:
    mov x19, x0

    /* alignment at handoff -> bit 3 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #3
    str x10, [x19, #448]

    /* informational: TPIDR_EL0 inside B */
    .inst 0xd53bd040                     /* mrs x0, TPIDR_EL0 */
    adrp x9, g_tpidr_in@PAGE
    str x0, [x9, g_tpidr_in@PAGEOFF]

    /* TSD must hold the scheduler-seeded M1 -> bit 0 */
    bl  Lt11_get
    LOADM1 x9
    cmp x0, x9
    cset x10, ne
    ldr x11, [x19, #448]
    orr x11, x11, x10
    str x11, [x19, #448]

    /* thread identity inside B vs pre-switch -> bit 2 */
    bl  _pthread_self
    ldr x9, [x19, #456]
    cmp x0, x9
    cset x10, ne
    lsl x10, x10, #2
    ldr x11, [x19, #448]
    orr x11, x11, x10
    str x11, [x19, #448]

    /* ---- yield ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

    /* ---- resumed: final switch back to the scheduler (never returns) ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

Lt11_entry_hang:                        /* unreachable */
    b   Lt11_entry_hang
