/*
 * t9_simd_probe.S — S0-T9 probe: callee-saved FP/SIMD register preservation
 * across ms_ctx_switch (aarch64, AAPCS64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Built and resolved exactly like
 * t8_gpr_probe.S: no link-time spike references; runtime dlsym after the
 * Mojo driver dlopen()s libmojito_spike.dylib.
 *
 * AAPCS64 requires the callee to preserve the LOW 64 BITS of v8-v15
 * (i.e. d8-d15); the upper halves are caller-saved. This probe fills
 * d8..d15 with distinct bit patterns inside the synthetic context, yields,
 * resumes, and verifies every pattern bit-exactly via fmov-to-GPR compares.
 *
 * Exported:
 *   Int32 t9_init(void)       0 = every required symbol resolved
 *   Int   t9_alloc(Int bytes) -> initial SP of a fresh guarded stack (0 = fail)
 *   void  t9_free(void)
 *   Int   t9_run(Int top)     corruption bitmask; 0 = all preserved
 *
 * Bit map returned by t9_run:
 *   0..7   d8..d15 (low 64 bits of v8..v15) corrupted inside B
 *   8      sp not 16-byte aligned at trampoline->entry handoff
 *   9      sp not 16-byte aligned at post-switch resume
 *   10..17 scheduler-side d8..d15 poison lost (main-context fps)
 */

.section __TEXT,__cstring,cstring_literals
Lsym_alloc:   .asciz "ms_stack_alloc"
Lsym_free:    .asciz "ms_stack_free"
Lsym_make:    .asciz "ms_ctx_make"
Lsym_switch:  .asciz "ms_ctx_switch"

.section __TEXT,__const
.align 3
Lt9_vals:
    .quad 0x3FF0000000000001             /* expected bits for d8  */
    .quad 0x3FF0000000000002             /* d9  */
    .quad 0x3FF0000000000004             /* d10 */
    .quad 0x3FF0000000000008             /* d11 */
    .quad 0x3FF0000000000010             /* d12 */
    .quad 0x3FF0000000000020             /* d13 */
    .quad 0x3FF0000000000040             /* d14 */
    .quad 0x3FF0000000000080             /* d15 */

/* Scheduler-side poison patterns: distinct from B's magics above so a
 * do-nothing switch cannot pass both checks at once. */
Lt9_poison:
    .quad 0x3FC00000000000A1             /* poison d8  */
    .quad 0x3FC00000000000A2             /* d9  */
    .quad 0x3FC00000000000A4             /* d10 */
    .quad 0x3FC00000000000A8             /* d11 */
    .quad 0x3FC00000000000B0             /* d12 */
    .quad 0x3FC00000000000C0             /* d13 */
    .quad 0x3FC00000000000E0             /* d14 */
    .quad 0x3FC0000000000010             /* d15 */

.data
.align 3
g_alloc:     .quad 0
g_free:      .quad 0
g_make:      .quad 0
g_switch:    .quad 0
g_base:      .quad 0
g_top:       .quad 0
/* shared block handed to the synthetic context (malloc'd by t9_run):
 *   +0    main ctx save area (ms_ctx_t is 168 bytes in contract v2)
 *   +192  b ctx save area
 *   +384  corruption mask written by entry before final switch
 */
g_shared:    .quad 0

.text

/* POISOND — load the scheduler-side poison patterns into d8-d15.
 * Clobbers x16 as pool pointer. */
.macro POISOND
    adrp x16, Lt9_poison@PAGE
    add  x16, x16, Lt9_poison@PAGEOFF
    ldr d8,  [x16, #0]
    ldr d9,  [x16, #8]
    ldr d10, [x16, #16]
    ldr d11, [x16, #24]
    ldr d12, [x16, #32]
    ldr d13, [x16, #40]
    ldr d14, [x16, #48]
    ldr d15, [x16, #56]
.endm

/* CHKPOISOND — verify d8-d15 still hold the poison patterns; leaves the
 * mismatch bitmask (bits 0..7) in x11. Clobbers x9, x10, x16. */
.macro CHKPOISOND
    adrp x16, Lt9_poison@PAGE
    add  x16, x16, Lt9_poison@PAGEOFF
    mov  x11, xzr
#define T9POISONCHK(idx, reg, bit)    \
    ldr  x9, [x16, #(idx*8)];         \
    fmov x10, reg;                    \
    cmp  x10, x9;                     \
    cset x10, ne;                     \
    lsl  x10, x10, #bit;              \
    orr  x11, x11, x10
    T9POISONCHK(0, d8,  0)
    T9POISONCHK(1, d9,  1)
    T9POISONCHK(2, d10, 2)
    T9POISONCHK(3, d11, 3)
    T9POISONCHK(4, d12, 4)
    T9POISONCHK(5, d13, 5)
    T9POISONCHK(6, d14, 6)
    T9POISONCHK(7, d15, 7)
#undef T9POISONCHK
.endm
.align 2

/* Int32 t9_init(void) -> 0 when every required symbol resolved */
.globl _t9_init
.extern _dlsym
_t9_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #-2                          /* RTLD_DEFAULT */
    adrp x1, Lsym_alloc@PAGE
    add  x1, x1, Lsym_alloc@PAGEOFF
    bl  _dlsym
    adrp x9, g_alloc@PAGE
    str x0, [x9, g_alloc@PAGEOFF]
    cbz x0, Lt9_missing
    mov x0, #-2
    adrp x1, Lsym_free@PAGE
    add  x1, x1, Lsym_free@PAGEOFF
    bl  _dlsym
    adrp x9, g_free@PAGE
    str x0, [x9, g_free@PAGEOFF]
    cbz x0, Lt9_missing
    mov x0, #-2
    adrp x1, Lsym_make@PAGE
    add  x1, x1, Lsym_make@PAGEOFF
    bl  _dlsym
    adrp x9, g_make@PAGE
    str x0, [x9, g_make@PAGEOFF]
    cbz x0, Lt9_missing
    mov x0, #-2
    adrp x1, Lsym_switch@PAGE
    add  x1, x1, Lsym_switch@PAGEOFF
    bl  _dlsym
    adrp x9, g_switch@PAGE
    str x0, [x9, g_switch@PAGEOFF]
    cbz x0, Lt9_missing
    mov w0, #0
    b   Lt9_init_done
Lt9_missing:
    mov w0, #1
Lt9_init_done:
    ldp x29, x30, [sp], #16
    ret

/* Int t9_alloc(Int bytes) -> initial SP or 0 */
.globl _t9_alloc
_t9_alloc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]
    adrp x9, g_base@PAGE
    add x1, x9, g_base@PAGEOFF
    adrp x9, g_top@PAGE
    add x2, x9, g_top@PAGEOFF
    blr x15
    cbz w0, Lt9_alloc_ok
    mov x0, #0
    b   Lt9_alloc_done
Lt9_alloc_ok:
    adrp x9, g_top@PAGE
    ldr x0, [x9, g_top@PAGEOFF]
Lt9_alloc_done:
    ldp x29, x30, [sp], #16
    ret

/* void t9_free(void) */
.globl _t9_free
_t9_free:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15
    ldp x29, x30, [sp], #16
    ret

/* Int t9_run(Int top) -> corruption bitmask (0 = all preserved).
 * The scheduler keeps the shared pointer in x19 across switches; that is a
 * legitimate reliance on GPR callee-savedness (exercised by T8 separately),
 * while THIS test targets d8-d15. */
.globl _t9_run
.extern _malloc
.extern _free
.align 2
_t9_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* top */
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt9_run_fail
    mov x19, x0                          /* shared */
    str xzr, [x19, #384]

    /* ms_ctx_make(shared+192, top, t9_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t9_entry@PAGE
    add  x2, x2, _t9_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* Poison the scheduler's own d8-d15, then enter B. If the impl fails
     * to save/restore the MAIN context's fps on the round trip, our poison
     * is gone when we come back and bits 10-17 trip below. */
    POISOND
    /* enter B (B runs to its yield) ... */
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* Re-poison before resuming B: B's magics must be restored from ITS
     * saved context; if the impl never saved them at the yield, B now sees
     * this scheduler-side poison instead and fails its check. */
    POISOND
    /* ... resume B: it verifies d8-d15 and its final switch lands here */
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* Scheduler-side: did OUR d8-d15 poisons survive? -> bits 10-17 */
    CHKPOISOND
    lsl x11, x11, #10
    ldr x10, [x19, #384]
    orr x10, x10, x11
    str x10, [x19, #384]

    ldr x21, [x19, #384]
    mov x0, x19
    bl  _free
    mov x0, x21

    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

Lt9_run_fail:
    mov x0, #-1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/*
 * B-side entry. x0 = shared pointer, parked in x19 (GPRs not under test).
 */
.globl _t9_entry
.align 2
_t9_entry:
    mov x19, x0
    str xzr, [x19, #384]                 /* mask = 0 */

    /* trampoline->entry handoff alignment -> bit 8 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #8
    str x10, [x19, #384]

    /* load magic patterns into d8..d15 from the literal pool */
    adrp x16, Lt9_vals@PAGE
    add  x16, x16, Lt9_vals@PAGEOFF
    ldr d8,  [x16, #0]
    ldr d9,  [x16, #8]
    ldr d10, [x16, #16]
    ldr d11, [x16, #24]
    ldr d12, [x16, #32]
    ldr d13, [x16, #40]
    ldr d14, [x16, #48]
    ldr d15, [x16, #56]

    /* ---- yield: from = B (+112), to = main (+0) ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- resumed: verify d8..d15 bit-exactly ---- */
    adrp x16, Lt9_vals@PAGE
    add  x16, x16, Lt9_vals@PAGEOFF
    ldr  x11, [x19, #384]                /* seed with entry-time bit 8 */

#define T9CHK(idx, reg, bit)          \
    ldr  x9, [x16, #(idx*8)];         \
    fmov x10, reg;                    \
    cmp  x10, x9;                     \
    cset x10, ne;                     \
    lsl  x10, x10, #bit;              \
    orr  x11, x11, x10

    T9CHK(0, d8,  0)
    T9CHK(1, d9,  1)
    T9CHK(2, d10, 2)
    T9CHK(3, d11, 3)
    T9CHK(4, d12, 4)
    T9CHK(5, d13, 5)
    T9CHK(6, d14, 6)
    T9CHK(7, d15, 7)

#undef T9CHK

    /* post-switch sp alignment -> bit 9 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #9
    orr x11, x11, x10

    str x11, [x19, #384]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

Lt9_entry_hang:                          /* unreachable */
    b    Lt9_entry_hang
