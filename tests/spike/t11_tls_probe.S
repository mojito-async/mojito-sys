/*
 * t11_tls_probe.S — S0-T11 probe: OS-thread TLS continuity across context
 * switches (aarch64, macOS arm64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Built and resolved exactly like
 * t8_gpr_probe.S: no link-time spike references; runtime dlsym after the
 * Mojo driver dlopen()s libmojito_spike.dylib.
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
 * Raw TLS-pointer register reads (TPIDR_EL0 / TPIDRRO_EL0) are captured and
 * exposed via getters for information only — on macOS arm64 libSystem may
 * legitimately rewrite TPIDR_EL0, and TPIDRRO_EL0 values are not guaranteed
 * stable read-to-read under userspace hardening, so register equality is
 * NOT gated on.
 *
 * Exported:
 *   Int32 t11_init(void)       0 = every required symbol resolved AND the
 *                                 TSD key created
 *   Int   t11_alloc(Int bytes) -> initial SP of fresh guarded stack (0=fail)
 *   void  t11_free(void)
 *   Int   t11_run(Int top)     verdict bitmask; 0 = TLS fully continuous
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

.section __TEXT,__cstring,cstring_literals
Lsym_alloc:    .asciz "ms_stack_alloc"
Lsym_free:     .asciz "ms_stack_free"
Lsym_make:     .asciz "ms_ctx_make"
Lsym_switch:   .asciz "ms_ctx_switch"
Lsym_keycreate:.asciz "pthread_key_create"
Lsym_setspec:  .asciz "pthread_setspecific"
Lsym_getspec:  .asciz "pthread_getspecific"
Lsym_self:     .asciz "pthread_self"

.data
.align 3
g_alloc:     .quad 0
g_free:      .quad 0
g_make:      .quad 0
g_switch:    .quad 0
g_keycreate: .quad 0
g_setspec:   .quad 0
g_getspec:   .quad 0
g_self:      .quad 0
g_key:       .quad 0                    /* pthread_key_t */
g_base:      .quad 0
g_top:       .quad 0
g_tpidr_pre: .quad 0                    /* informational */
g_tpidr_in:  .quad 0                    /* informational */
g_tpidr_post:.quad 0                    /* informational */
g_dbg_setrc: .quad 0                    /* DBG: setspecific return code */
g_dbg_get1:  .quad 0                    /* DBG: getspecific after seed  */
/* shared block handed to the synthetic context (malloc'd by t11_run):
 *   +0    main ctx save area (ms_ctx_t is 168 bytes in contract v2)
 *   +192  b ctx save area
 *   +384  mask / alignment seed
 *   +392  pthread_self captured by scheduler before entering
 */
g_shared:    .quad 0

.macro LOADM1 r                            /* 0x7E5711CE: seeded magic */
    movz \r, #0x11CE
    movk \r, #0x7E57, lsl #16
.endm

.text
.align 2

.globl _t11_init
.extern _dlsym
_t11_init:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x29, sp
    mov x0, #-2                          /* RTLD_DEFAULT */
    adrp x1, Lsym_alloc@PAGE
    add  x1, x1, Lsym_alloc@PAGEOFF
    bl  _dlsym
    adrp x9, g_alloc@PAGE
    str x0, [x9, g_alloc@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_free@PAGE
    add  x1, x1, Lsym_free@PAGEOFF
    bl  _dlsym
    adrp x9, g_free@PAGE
    str x0, [x9, g_free@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_make@PAGE
    add  x1, x1, Lsym_make@PAGEOFF
    bl  _dlsym
    adrp x9, g_make@PAGE
    str x0, [x9, g_make@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_switch@PAGE
    add  x1, x1, Lsym_switch@PAGEOFF
    bl  _dlsym
    adrp x9, g_switch@PAGE
    str x0, [x9, g_switch@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_keycreate@PAGE
    add  x1, x1, Lsym_keycreate@PAGEOFF
    bl  _dlsym
    adrp x9, g_keycreate@PAGE
    str x0, [x9, g_keycreate@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_setspec@PAGE
    add  x1, x1, Lsym_setspec@PAGEOFF
    bl  _dlsym
    adrp x9, g_setspec@PAGE
    str x0, [x9, g_setspec@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_getspec@PAGE
    add  x1, x1, Lsym_getspec@PAGEOFF
    bl  _dlsym
    adrp x9, g_getspec@PAGE
    str x0, [x9, g_getspec@PAGEOFF]
    cbz x0, Lt11_missing
    mov x0, #-2
    adrp x1, Lsym_self@PAGE
    add  x1, x1, Lsym_self@PAGEOFF
    bl  _dlsym
    adrp x9, g_self@PAGE
    str x0, [x9, g_self@PAGEOFF]
    cbz x0, Lt11_missing

    /* create the TSD key: pthread_key_create(&g_key, NULL) */
    adrp x9, g_keycreate@PAGE
    ldr x15, [x9, g_keycreate@PAGEOFF]
    adrp x9, g_key@PAGE
    add x0, x9, g_key@PAGEOFF
    mov x1, #0                           /* no destructor */
    blr x15
    cbnz w0, Lt11_missing
    mov w0, #0
    b   Lt11_init_done
Lt11_missing:
    mov w0, #1
Lt11_init_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/* Int t11_alloc(Int bytes) -> initial SP or 0 */
.globl _t11_alloc
_t11_alloc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]
    adrp x9, g_base@PAGE
    add x1, x9, g_base@PAGEOFF
    adrp x9, g_top@PAGE
    add x2, x9, g_top@PAGEOFF
    blr x15
    cbz w0, Lt11_alloc_ok
    mov x0, #0
    b   Lt11_alloc_done
Lt11_alloc_ok:
    adrp x9, g_top@PAGE
    ldr x0, [x9, g_top@PAGEOFF]
Lt11_alloc_done:
    ldp x29, x30, [sp], #16
    ret

.globl _t11_free
_t11_free:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15
    ldp x29, x30, [sp], #16
    ret

/* helper: GETSPEC -> x0 (clobbers x15, x16) */
Lt11_get:
    adrp x16, g_getspec@PAGE
    ldr  x15, [x16, g_getspec@PAGEOFF]
    adrp x16, g_key@PAGE
    ldr  x0, [x16, g_key@PAGEOFF]
    br   x15

/* helper: SETSPEC(value in x0) — pthread_setspecific(key, value):
 * key goes in x0, VALUE goes in x1. Clobbers x15, x16, x1, x2. */
Lt11_set:
    mov  x2, x0                          /* preserve requested value */
    adrp x16, g_setspec@PAGE
    ldr  x15, [x16, g_setspec@PAGEOFF]
    adrp x16, g_key@PAGE
    ldr  x0, [x16, g_key@PAGEOFF]        /* arg0: key */
    mov  x1, x2                          /* arg1: value */
    br   x15

/* Int t11_run(Int top) -> verdict bitmask (0 = TLS fully continuous).
 * Shared pointer parked in x19 across switches (legitimate reliance on GPR
 * callee-savedness — exercised exhaustively by T8). */
.globl _t11_run
.extern _malloc
.extern _free
.align 2
_t11_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* top */
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
    adrp x9, g_dbg_setrc@PAGE
    str x0, [x9, g_dbg_setrc@PAGEOFF]
    bl  Lt11_get
    adrp x9, g_dbg_get1@PAGE
    str x0, [x9, g_dbg_get1@PAGEOFF]
    LOADM1 x0
    bl  Lt11_set                        /* re-seed to be sure */
    adrp x9, g_self@PAGE
    ldr x15, [x9, g_self@PAGEOFF]
    blr x15                              /* pthread_self() */
    str x0, [x19, #392]
    str xzr, [x19, #384]

    /* ms_ctx_make(shared+192, top, t11_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t11_entry@PAGE
    add  x2, x2, _t11_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* enter B; B yields once; its final switch lands here */
    mov x0, x19                          /* from = main ctx */
    add x1, x19, #192                    /* to   = b ctx    */
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- back on the scheduler: post-switch re-verify -> bit 1 ---- */
    bl  Lt11_get
    LOADM1 x9
    cmp x0, x9
    cset x10, ne
    ldr x11, [x19, #384]
    orr x11, x11, x10
    str x11, [x19, #384]

    /* informational: TPIDR_EL0 after the run */
    .inst 0xd53bd040                     /* mrs x0, TPIDR_EL0 */
    adrp x9, g_tpidr_post@PAGE
    str x0, [x9, g_tpidr_post@PAGEOFF]

    ldr x21, [x19, #384]
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
.globl _t11_dbg_setrc
_t11_dbg_setrc:
    adrp x8, g_dbg_setrc@PAGE
    ldr x0, [x8, g_dbg_setrc@PAGEOFF]
    ret
.globl _t11_dbg_get1
_t11_dbg_get1:
    adrp x8, g_dbg_get1@PAGE
    ldr x0, [x8, g_dbg_get1@PAGEOFF]
    ret
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
    str x10, [x19, #384]

    /* informational: TPIDR_EL0 inside B */
    .inst 0xd53bd040                     /* mrs x0, TPIDR_EL0 */
    adrp x9, g_tpidr_in@PAGE
    str x0, [x9, g_tpidr_in@PAGEOFF]

    /* TSD must hold the scheduler-seeded M1 -> bit 0 */
    bl  Lt11_get
    LOADM1 x9
    cmp x0, x9
    cset x10, ne
    ldr x11, [x19, #384]
    orr x11, x11, x10
    str x11, [x19, #384]

    /* thread identity inside B vs pre-switch -> bit 2 */
    adrp x9, g_self@PAGE
    ldr x15, [x9, g_self@PAGEOFF]
    blr x15                              /* pthread_self() */
    ldr x9, [x19, #392]
    cmp x0, x9
    cset x10, ne
    lsl x10, x10, #2
    ldr x11, [x19, #384]
    orr x11, x11, x10
    str x11, [x19, #384]

    /* ---- yield ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- resumed: final switch back to the scheduler (never returns) ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

Lt11_entry_hang:                        /* unreachable */
    b   Lt11_entry_hang
