/*
 * t11_tls_probe.S — S0-T11 probe: OS-thread TLS continuity across context
 * switches (aarch64, macOS arm64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Built and resolved exactly like
 * t8_gpr_probe.S: no link-time spike references; runtime dlsym after the
 * Mojo driver dlopen()s libmojito_spike.dylib.
 *
 * A context switch on ONE OS thread must not disturb thread-local state:
 * the thread identity (pthread_self) and the TLS pointer register
 * (TPIDRROEL0, the userspace-readable TLS base Apple platforms use for
 * _pthread TSD) must be identical before, during (inside the synthetic
 * context), and after a suspend/resume round trip. This probe captures both
 * values at all three points and compares them.
 *
 * Exported:
 *   Int32 t11_init(void)       0 = every required symbol resolved
 *   Int   t11_alloc(Int bytes) -> initial SP of fresh guarded stack (0 = fail)
 *   void  t11_free(void)
 *   Int   t11_run(Int top)     verdict bitmask; 0 = TLS fully continuous
 *
 * Bit map returned by t11_run:
 *   0   pthread_self inside B differs from pre-switch value
 *   1   TPIDRROEL0 inside B differs from pre-switch value
 *   2   pthread_self at post-resume differs from in-B value
 *   3   TPIDRROEL0 at post-resume differs from in-B value
 *   4   sp not 16-byte aligned at trampoline->entry handoff
 */

.section __TEXT,__cstring,cstring_literals
Lsym_alloc:   .asciz "ms_stack_alloc"
Lsym_free:    .asciz "ms_stack_free"
Lsym_make:    .asciz "ms_ctx_make"
Lsym_switch:  .asciz "ms_ctx_switch"

.data
.align 3
g_alloc:     .quad 0
g_free:      .quad 0
g_make:      .quad 0
g_switch:    .quad 0
g_base:      .quad 0
g_top:       .quad 0
/* shared block handed to the synthetic context (malloc'd by t11_run):
 *   +0    main ctx save area
 *   +112  b ctx save area
 *   +224  mask
 *   +232  pthread_self captured by scheduler before entering
 *   +240  TPIDRROEL0 captured by scheduler before entering
 */
g_shared:    .quad 0

.text
.align 2

.globl _t11_init
.extern _dlsym
.extern _pthread_self
_t11_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #-2
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
    mov w0, #0
    b   Lt11_init_done
Lt11_missing:
    mov w0, #1
Lt11_init_done:
    ldp x29, x30, [sp], #16
    ret

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

.globl _t11_run
.extern _malloc
.extern _free
.align 2
_t11_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0
    mov x0, #512
    bl  _malloc
    cbz x0, Lt11_run_fail
    mov x19, x0

    /* scheduler-side pre-capture: thread identity + TLS base */
    bl  _pthread_self
    str x0, [x19, #400]
    .inst 0xd53bd040                    /* mrs x0, TPIDRROEL0 */
    str x0, [x19, #408]
    str xzr, [x19, #384]

    /* ms_ctx_make(shared+112, top, t11_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t11_entry@PAGE
    add  x2, x2, _t11_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* enter B; yield; resume; final switch lands here */
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

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

/* B-side entry. x0 = shared pointer, parked in x19. */
.globl _t11_entry
.align 2
_t11_entry:
    mov x19, x0

    /* alignment at handoff -> bit 4 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #4
    str x10, [x19, #384]

    /* capture pair inside B */
    bl  _pthread_self                   /* -> x0 */
    mov x21, x0
    .inst 0xd53bd041                    /* mrs x1, TPIDRROEL0 */

    /* compare with scheduler's pre-capture -> bits 0,1 */
    ldr x9,  [x19, #400]
    cmp x21, x9
    cset x10, ne
    orr x11, x10, xzr
    ldr x9,  [x19, #408]
    cmp x1,  x9
    cset x10, ne
    lsl x10, x10, #1
    orr x11, x11, x10
    ldr x10, [x19, #384]
    orr x11, x11, x10
    str x11, [x19, #384]

    /* stash the in-B pair for the post-resume comparison */
    str x21, [x19, #416]
    str x1,  [x19, #424]

    /* ---- yield ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- resumed: capture third pair, compare vs in-B -> bits 2,3 ---- */
    bl  _pthread_self
    mov x21, x0
    .inst 0xd53bd041                    /* mrs x1, TPIDRROEL0 */
    ldr x11, [x19, #384]
    ldr x9,  [x19, #416]
    cmp x21, x9
    cset x10, ne
    lsl x10, x10, #2
    orr x11, x11, x10
    ldr x9,  [x19, #424]
    cmp x1,  x9
    cset x10, ne
    lsl x10, x10, #3
    orr x11, x11, x10
    str x11, [x19, #384]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

Lt11_entry_hang:                        /* unreachable */
    b   Lt11_entry_hang
