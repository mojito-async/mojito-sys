/*
 * t9_simd_probe.S — S0/M1.4-T9 probe: callee-saved FP/SIMD register
 * preservation across ms_context_switch (aarch64, AAPCS64, Mach-O).
 * RE-POINTED (#128) at the PRODUCTION native/posix/ms_context_aarch64.S
 * `ms_context_switch`/`ms_context_init`, called directly (statically
 * linked, no dlsym indirection -- see t8_gpr_probe.S's header for the
 * full account of why; this probe follows the identical pattern).
 *
 * AAPCS64 requires the callee to preserve the LOW 64 BITS of v8-v15
 * (i.e. d8-d15); the upper halves are caller-saved. This probe fills
 * d8..d15 with distinct bit patterns inside the synthetic context, yields,
 * resumes, and verifies every pattern bit-exactly via fmov-to-GPR compares.
 *
 * Unlike t8_gpr_probe.S, x19 is never part of the payload under test here
 * (only d8-d15 are), so it is safe to keep "shared" parked in x19 across
 * POISOND -- no g_shared reload is needed for that reason. g_shared is
 * still used to pass the pointer into t9_entry (a fresh context has no
 * other way to receive it before x19 is established there).
 *
 * Exported:
 *   Int   t9_run(Int stack_low, Int stack_top)   corruption bitmask (0 =
 *                                                 all preserved; -1 = the
 *                                                 probe's own malloc failed)
 *
 * v3 LIFECYCLE (#128): main_ctx is self-captured (ms_context_switch(main,
 * main)) before the first switch-out, exactly like t8_gpr_probe.S.
 *
 * Shared block layout (malloc'd by t9_run, 1024 bytes):
 *   +0    main ctx save area (MS_CONTEXT_SIZE is 200 bytes; 224 reserved)
 *   +224  B ctx save area
 *   +448  corruption mask written by entry before final switch
 *
 * Bit map returned by t9_run (unchanged from the S0 version):
 *   0..7   d8..d15 (low 64 bits of v8..v15) corrupted inside B
 *   8      sp not 16-byte aligned at trampoline->entry handoff
 *   9      sp not 16-byte aligned at post-switch resume
 *   10..17 scheduler-side d8..d15 poison lost (main-context fps)
 */

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
/* shared block handed to the synthetic context (malloc'd by t9_run):
 *   +0    main ctx save area
 *   +224  b ctx save area
 *   +448  corruption mask written by entry before final switch
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

/* T9POISONCHK idx, reg, bit — one poison-register comparison, OR'd into
 * x11 at the given bit. Clobbers x9, x10.
 *
 * MUST be a GNU `.macro` (one instruction per line), NOT a C-preprocessor
 * `#define` with `;`-joined instructions on one logical line: found while
 * mutation-testing this probe (deliberately breaking a check and
 * confirming the test catches it, per repo convention) that Apple's
 * clang integrated assembler treats `;` as an END-OF-LINE COMMENT
 * character for this target, not a statement separator. A `#define`
 * whose body joins several instructions with `;` therefore silently
 * assembles to ONLY ITS FIRST INSTRUCTION per invocation -- the rest is
 * treated as a comment and discarded, with NO error or warning from
 * either cpp or the assembler. That made this exact check vacuous (it
 * could never trip regardless of real corruption) before this fix; see
 * the PR body for the full account and mojito-sys#205. */
.macro T9POISONCHK idx, reg, bit
    ldr  x9, [x16, #(\idx*8)]
    fmov x10, \reg
    cmp  x10, x9
    cset x10, ne
    lsl  x10, x10, #\bit
    orr  x11, x11, x10
.endm

/* CHKPOISOND — verify d8-d15 still hold the poison patterns; leaves the
 * mismatch bitmask (bits 0..7) in x11. Clobbers x9, x10, x16. */
.macro CHKPOISOND
    adrp x16, Lt9_poison@PAGE
    add  x16, x16, Lt9_poison@PAGEOFF
    mov  x11, xzr
    T9POISONCHK 0, d8,  0
    T9POISONCHK 1, d9,  1
    T9POISONCHK 2, d10, 2
    T9POISONCHK 3, d11, 3
    T9POISONCHK 4, d12, 4
    T9POISONCHK 5, d13, 5
    T9POISONCHK 6, d14, 6
    T9POISONCHK 7, d15, 7
.endm
.align 2

/* Int t9_run(Int stack_low [x0], Int stack_top [x1]) -> corruption bitmask
 * (0 = all preserved; -1 = probe's own malloc failed).
 * The scheduler keeps the shared pointer in x19 across switches; that is a
 * legitimate reliance on GPR callee-savedness (exercised by T8 separately),
 * while THIS test targets d8-d15. */
.globl _t9_run
.extern _malloc
.extern _free
.extern _ms_context_init
.extern _ms_context_switch
.align 2
_t9_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* stack_low */
    mov x22, x1                          /* stack_top */
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt9_run_fail
    adrp x16, g_shared@PAGE
    str x0, [x16, g_shared@PAGEOFF]
    str xzr, [x0, #448]
    mov x19, x0                          /* shared */

    /* self-capture main ctx (v3 lifecycle) */
    mov x0, x19
    mov x1, x19
    bl  _ms_context_switch

    /* ms_context_init(shared+224, stack_low, stack_size, t9_entry, shared) */
    add x0, x19, #224
    mov x1, x20
    sub x2, x22, x20
    adrp x3, _t9_entry@PAGE
    add  x3, x3, _t9_entry@PAGEOFF
    mov x4, x19
    bl  _ms_context_init

    /* Poison the scheduler's own d8-d15, then enter B. If the impl fails
     * to save/restore the MAIN context's fps on the round trip, our poison
     * is gone when we come back and bits 10-17 trip below. x19 is never
     * poisoned (only d8-d15 are), so it stays valid as "shared" here
     * unlike t8_gpr_probe.S's x19-under-test case. */
    POISOND
    mov x0, x19
    add x1, x19, #224
    bl  _ms_context_switch

    /* Re-poison before resuming B: B's magics must be restored from ITS
     * saved context; if the impl never saved them at the yield, B now sees
     * this scheduler-side poison instead and fails its check. */
    POISOND
    mov x0, x19
    add x1, x19, #224
    bl  _ms_context_switch

    /* Scheduler-side: did OUR d8-d15 poisons survive? -> bits 10-17 */
    CHKPOISOND
    lsl x11, x11, #10
    ldr x10, [x19, #448]
    orr x10, x10, x11
    str x10, [x19, #448]

    ldr x21, [x19, #448]
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
    str xzr, [x19, #448]                 /* mask = 0 */

    /* trampoline->entry handoff alignment -> bit 8 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #8
    str x10, [x19, #448]

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

    /* ---- yield: from = B (+224), to = main (+0) ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

    /* ---- resumed: verify d8..d15 bit-exactly ---- */
    adrp x16, Lt9_vals@PAGE
    add  x16, x16, Lt9_vals@PAGEOFF
    ldr  x11, [x19, #448]                /* seed with entry-time bit 8 */

    /* Same shape as T9POISONCHK (defined above, near CHKPOISOND) -- reused
     * directly rather than duplicating another #define here (that
     * duplicate #define was the OTHER vacuous-check copy this same bug
     * hid in before the fix; see T9POISONCHK's comment). */
    T9POISONCHK 0, d8,  0
    T9POISONCHK 1, d9,  1
    T9POISONCHK 2, d10, 2
    T9POISONCHK 3, d11, 3
    T9POISONCHK 4, d12, 4
    T9POISONCHK 5, d13, 5
    T9POISONCHK 6, d14, 6
    T9POISONCHK 7, d15, 7

    /* post-switch sp alignment -> bit 9 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #9
    orr x11, x11, x10

    str x11, [x19, #448]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

Lt9_entry_hang:                          /* unreachable */
    b    Lt9_entry_hang
