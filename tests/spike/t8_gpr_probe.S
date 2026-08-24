/*
 * t8_gpr_probe.S — S0-T8 probe: callee-saved GPR preservation across
 * ms_ctx_switch (aarch64, AAPCS64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Assembled to a relocatable object and
 * linked INTO the t8_gpr_preservation executable; it contains no link-time
 * references to the spike, so the executable always builds. Spike symbols
 * are resolved at runtime via dlsym(RTLD_DEFAULT) after the Mojo driver has
 * dlopen()ed libmojito_spike.dylib. Implementation absent => deterministic
 * RED verdict from the driver, never a crash.
 *
 * Exported:
 *   Int32 t8_init(void)       0 = every required symbol resolved
 *   Int   t8_alloc(Int bytes) -> initial SP of a fresh guarded stack (0 = fail)
 *   void  t8_free(void)
 *   Int   t8_run(Int top)     corruption bitmask; 0 = all preserved
 *
 * Scenario: the scheduler side makes context B on the guarded stack via
 * ms_ctx_make and enters it with ms_ctx_switch. BOTH sides are checked:
 *
 *   - B's entry fills x19-x28 and fp(x29) with per-register magic values,
 *     yields twice (checking lr at each resume site), verifies every magic
 *     after resume, and finally switches back.
 *   - The scheduler poisons its own x19-x28 with anti-magic values before
 *     EVERY switch and re-verifies them after every return. An impl that
 *     omits saving/restoring the main context's callee-saved GPRs therefore
 *     trips bits 14-23 instead of passing vacuously (a do-nothing switch
 *     would otherwise leave B's magics untouched in registers).
 *
 * Bit map returned by t8_run:
 *   0..9   x19..x28 corrupted inside B
 *   10     fp (x29) corrupted inside B
 *   11     lr (x30) corrupted (checked at both resume sites)
 *   12     sp not 16-byte aligned at trampoline->entry handoff
 *   13     sp not 16-byte aligned at post-switch resume
 *   14..23 main-context x19..x28 poison lost (scheduler side)
 */

.section __TEXT,__cstring,cstring_literals
Lsym_alloc:   .asciz "ms_stack_alloc"
Lsym_free:    .asciz "ms_stack_free"
Lsym_make:    .asciz "ms_ctx_make"
Lsym_switch:  .asciz "ms_ctx_switch"

.data
.align 3
g_alloc:     .quad 0                    /* ms_stack_alloc */
g_free:      .quad 0                    /* ms_stack_free */
g_make:      .quad 0                    /* ms_ctx_make */
g_switch:    .quad 0                    /* ms_ctx_switch */
g_base:      .quad 0                    /* allocation base */
g_top:       .quad 0                    /* initial SP */
/* shared block handed to the synthetic context (malloc'd by t8_run):
 *   +0    main ctx save area (ms_ctx_t is 168 bytes in contract v2)
 *   +192  b ctx save area
 *   +384  corruption mask written by entry before final switch
 *   +392  initial SP (informational)
 */
g_shared:    .quad 0

.text
.align 2

/* SETREG r, n — fill register r with the magic value for slot n in {0..9}.
 * Layout: [63:48]=0xBEEF [47:32]=0xFE00+n [31:16]=0xC0DE [15:0]=0x5000+n */
.macro SETREG r, n
    movz \r, #(0x5000 + \n)
    movk \r, #0xC0DE, lsl #16
    movk \r, #(0xFE00 + \n), lsl #32
    movk \r, #0xBEEF, lsl #48
.endm

/* CHKREG r, n, bit — accumulate mismatch into x11. Clobbers x9, x10. */
.macro CHKREG r, n, bit
    movz x9, #(0x5000 + \n)
    movk x9, #0xC0DE, lsl #16
    movk x9, #(0xFE00 + \n), lsl #32
    movk x9, #0xBEEF, lsl #48
    cmp  \r, x9
    cset x10, ne
    lsl  x10, x10, #\bit
    orr  x11, x11, x10
.endm

/* POISON r, n — fill register r with an anti-magic value for slot n.
 * Deliberately distinct from SETREG values so a do-nothing switch cannot
 * confuse "B's magic survived" with "main's poison survived".
 * Layout: [63:48]=0xDEAD [47:32]=0xBAD0+n [31:16]=0x1234 [15:0]=0xA000+n */
.macro POISON r, n
    movz \r, #(0xA000 + \n)
    movk \r, #0x1234, lsl #16
    movk \r, #(0xBAD0 + \n), lsl #32
    movk \r, #0xDEAD, lsl #48
.endm

/* CHKPOISON r, n — accumulate mismatch vs poison into x11 at bit 14+n.
 * (Scheduler-side poison bits are fixed at 14..23.) Clobbers x9/x10. */
.macro CHKPOISON r, n
    movz x9, #(0xA000 + \n)
    movk x9, #0x1234, lsl #16
    movk x9, #(0xBAD0 + \n), lsl #32
    movk x9, #0xDEAD, lsl #48
    cmp  \r, x9
    cset x10, ne
    lsl  x10, x10, #(14 + \n)
    orr  x11, x11, x10
.endm

.macro POISONALL
    POISON x19, 0
    POISON x20, 1
    POISON x21, 2
    POISON x22, 3
    POISON x23, 4
    POISON x24, 5
    POISON x25, 6
    POISON x26, 7
    POISON x27, 8
    POISON x28, 9
.endm

/* CHKPOISONALL base_bit — verify all ten poisons and OR mismatch bits
 * base_bit+0..9 into the mask at [shared+384]. Reloads shared itself;
 * clobbers x9-x11, x16. */
.macro CHKPOISONALL base
    mov  x11, xzr
    CHKPOISON x19, 0
    CHKPOISON x20, 1
    CHKPOISON x21, 2
    CHKPOISON x22, 3
    CHKPOISON x23, 4
    CHKPOISON x24, 5
    CHKPOISON x25, 6
    CHKPOISON x26, 7
    CHKPOISON x27, 8
    CHKPOISON x28, 9
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x10, [x9, #384]
    orr  x10, x10, x11
    str  x10, [x9, #384]
.endm

/* Int32 t8_init(void) -> 0 when every required symbol resolved */
.globl _t8_init
.extern _dlsym
_t8_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #-2                          /* RTLD_DEFAULT */
    adrp x1, Lsym_alloc@PAGE
    add  x1, x1, Lsym_alloc@PAGEOFF
    bl  _dlsym
    adrp x9, g_alloc@PAGE
    str x0, [x9, g_alloc@PAGEOFF]
    cbz x0, Lt8_missing
    mov x0, #-2
    adrp x1, Lsym_free@PAGE
    add  x1, x1, Lsym_free@PAGEOFF
    bl  _dlsym
    adrp x9, g_free@PAGE
    str x0, [x9, g_free@PAGEOFF]
    cbz x0, Lt8_missing
    mov x0, #-2
    adrp x1, Lsym_make@PAGE
    add  x1, x1, Lsym_make@PAGEOFF
    bl  _dlsym
    adrp x9, g_make@PAGE
    str x0, [x9, g_make@PAGEOFF]
    cbz x0, Lt8_missing
    mov x0, #-2
    adrp x1, Lsym_switch@PAGE
    add  x1, x1, Lsym_switch@PAGEOFF
    bl  _dlsym
    adrp x9, g_switch@PAGE
    str x0, [x9, g_switch@PAGEOFF]
    cbz x0, Lt8_missing
    mov w0, #0
    b   Lt8_init_done
Lt8_missing:
    mov w0, #1
Lt8_init_done:
    ldp x29, x30, [sp], #16
    ret

/* Int t8_alloc(Int bytes) -> initial SP or 0 */
.globl _t8_alloc
_t8_alloc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]       /* x15: caller-saved scratch */
    adrp x9, g_base@PAGE
    add x1, x9, g_base@PAGEOFF           /* out_base */
    adrp x9, g_top@PAGE
    add x2, x9, g_top@PAGEOFF            /* out_top */
    blr x15                              /* ms_stack_alloc(bytes, ...) */
    cbz w0, Lt8_alloc_ok                 /* C int 0 == success */
    mov x0, #0
    b   Lt8_alloc_done
Lt8_alloc_ok:
    adrp x9, g_top@PAGE
    ldr x0, [x9, g_top@PAGEOFF]
Lt8_alloc_done:
    ldp x29, x30, [sp], #16
    ret

/* void t8_free(void) */
.globl _t8_free
_t8_free:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15
    ldp x29, x30, [sp], #16
    ret

/* Int t8_run(Int top) -> corruption bitmask (0 = all preserved).
 * Callee-saved x19-x28 are poisoned/restored around this function for our
 * caller; all scheduler bookkeeping lives in memory, not across switches. */
.globl _t8_run
.extern _malloc
.extern _free
.align 2
_t8_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!

    mov x20, x0                          /* top (used only below) */
    mov x0, #1024                        /* shared block size */
    bl  _malloc
    cbz x0, Lt8_run_fail
    adrp x16, g_shared@PAGE
    str x0, [x16, g_shared@PAGEOFF]      /* shared = malloc'd block */
    str xzr, [x0, #384]                  /* result = 0 */
    str x20, [x0, #392]                  /* informational */

    /* ms_ctx_make(shared+192, top, t8_entry, shared) */
    mov x19, x0
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t8_entry@PAGE
    add  x2, x2, _t8_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* enter B; poison first so the main ctx saves poisoned state */
    POISONALL
    adrp x9, g_shared@PAGE
    ldr x0, [x9, g_shared@PAGEOFF]       /* from = main ctx (shared+0)   */
    adrp x9, g_shared@PAGE
    ldr x1, [x9, g_shared@PAGEOFF]
    add x1, x1, #192                     /* to   = b ctx     (shared+192) */
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
Lt8_sched1:
    /* resumed after yield#1: poisons must have survived the round trip */
    CHKPOISONALL 14
    /* poison again and resume B: if the impl failed to save B's regs at
     * its yield, B sees this fresh poison instead of its magics */
    POISONALL
    adrp x9, g_shared@PAGE
    ldr x0, [x9, g_shared@PAGEOFF]
    adrp x9, g_shared@PAGE
    ldr x1, [x9, g_shared@PAGEOFF]
    add x1, x1, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
Lt8_sched2:
    CHKPOISONALL 14
    POISONALL
    adrp x9, g_shared@PAGE
    ldr x0, [x9, g_shared@PAGEOFF]
    adrp x9, g_shared@PAGE
    ldr x1, [x9, g_shared@PAGEOFF]
    add x1, x1, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
Lt8_sched3:
    CHKPOISONALL 14

    adrp x9, g_shared@PAGE
    ldr x21, [x9, g_shared@PAGEOFF]
    ldr x22, [x21, #384]                 /* mask */
    mov x0, x21
    bl  _free
    mov x0, x22

    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

Lt8_run_fail:
    mov x0, #-1
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/*
 * B-side entry. x0 = shared pointer.
 *
 * Register discipline: x19-x28 all carry magic payloads under test, so no
 * register value (incl. cached adrp results in x16/x17) may be assumed
 * valid across ms_ctx_switch; every global access reloads its own adrp.
 */
.globl _t8_entry
.align 2
_t8_entry:
    adrp x16, g_shared@PAGE
    str  x0, [x16, g_shared@PAGEOFF]     /* stash userdata */

    /* trampoline->entry handoff alignment -> bit 12 */
    mov  x14, sp
    tst  x14, #15
    cset x10, ne
    lsl  x10, x10, #12
    str  x10, [x0, #384]                 /* seed mask */

    SETREG x19, 0
    SETREG x20, 1
    SETREG x21, 2
    SETREG x22, 3
    SETREG x23, 4
    SETREG x24, 5
    SETREG x25, 6
    SETREG x26, 7
    SETREG x27, 8
    SETREG x28, 9
    movz x29, #0x501C                    /* fp magic */

    /* ---- yield #1: from = B (+192), to = main (+0) ---- */
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    add  x0, x0, #192
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    adrp x16, g_switch@PAGE
    ldr  x15, [x16, g_switch@PAGEOFF]
    blr  x15
Lt8_ret1:
    /* ---- resumed at RA(yield#1): lr must point exactly here ---- */
    adr  x14, Lt8_ret1
    cmp  x30, x14
    cset x10, ne
    lsl  x10, x10, #11
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x11, [x9, #384]
    orr  x11, x11, x10
    str  x11, [x9, #384]

    /* ---- yield #2 ---- */
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    add  x0, x0, #192
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    adrp x16, g_switch@PAGE
    ldr  x15, [x16, g_switch@PAGEOFF]
    blr  x15
Lt8_ret2:
    /* ---- resumed at RA(yield#2): lr check for this site ---- */
    adr  x14, Lt8_ret2
    cmp  x30, x14
    cset x10, ne
    lsl  x10, x10, #11
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x11, [x9, #384]
    orr  x11, x11, x10

    CHKREG x19, 0, 0
    CHKREG x20, 1, 1
    CHKREG x21, 2, 2
    CHKREG x22, 3, 3
    CHKREG x23, 4, 4
    CHKREG x24, 5, 5
    CHKREG x25, 6, 6
    CHKREG x26, 7, 7
    CHKREG x27, 8, 8
    CHKREG x28, 9, 9

    /* fp (x29) -> bit 10 */
    movz x9, #0x501C
    cmp  x29, x9
    cset x10, ne
    lsl  x10, x10, #10
    orr  x11, x11, x10

    /* post-switch sp alignment -> bit 13 */
    mov  x14, sp
    tst  x14, #15
    cset x10, ne
    lsl  x10, x10, #13
    orr  x11, x11, x10

    /* store verdict (reload shared; x9 was clobbered by the fp check) */
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    str  x11, [x9, #384]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add  x0, x9, #192
    mov  x1, x9
    adrp x16, g_switch@PAGE
    ldr  x15, [x16, g_switch@PAGEOFF]
    blr  x15

Lt8_entry_hang:                          /* unreachable */
    b    Lt8_entry_hang
