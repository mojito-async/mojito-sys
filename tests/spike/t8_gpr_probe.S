/*
 * t8_gpr_probe.S — S0/M1.4-T8 probe: callee-saved GPR preservation across
 * ms_context_switch (aarch64, AAPCS64, Mach-O). RE-POINTED (#128) at the
 * PRODUCTION native/posix/ms_context_aarch64.S `ms_context_switch` /
 * `ms_context_init`, called directly (statically linked, no dlsym
 * indirection -- unlike the S0-era version, the production backend this
 * probe now drives already exists, so there is no "implementation not
 * built yet" case to defer past link time for).
 *
 * Exported:
 *   Int   t8_run(Int stack_low, Int stack_top)   corruption bitmask (0 =
 *                                                 all preserved; -1 = the
 *                                                 probe's own malloc failed)
 *
 * Scenario: unchanged from the S0 version --  the scheduler side makes
 * context B on the caller-supplied [stack_low, stack_top) span via
 * ms_context_init and enters it with ms_context_switch. BOTH sides are
 * checked:
 *
 *   - B's entry fills x19-x28 and fp(x29) with per-register magic values,
 *     yields twice (checking lr at each resume site), verifies every magic
 *     after resume, and finally switches back.
 *   - The scheduler poisons its own x19-x28 with anti-magic values before
 *     EVERY switch and re-verifies them after every return.
 *
 * v3 LIFECYCLE (#128, the one behavior change from the S0-era backend):
 * ms_context records now carry a per-context state word and trap loudly on
 * a switch into DEAD/RUNNING/FINISHED storage. The main context is
 * self-captured (ms_context_switch(main, main)) before anything switches
 * OUT of it, exactly like every re-pointed Mojo T-test does; the S0
 * backend had no such state machine and never needed this.
 *
 * Shared block layout (malloc'd by t8_run, 1024 bytes):
 *   +0    main ctx save area (MS_CONTEXT_SIZE is 200 bytes; 224 reserved,
 *         same 24-byte margin convention the S0-era 192-vs-168 pairing used)
 *   +224  B ctx save area
 *   +448  corruption mask written by entry before final switch
 *   +456  initial SP (informational)
 *
 * Bit map returned by t8_run (unchanged from the S0 version):
 *   0..9   x19..x28 corrupted inside B
 *   10     fp (x29) corrupted inside B
 *   11     lr (x30) corrupted (checked at both resume sites)
 *   12     sp not 16-byte aligned at trampoline->entry handoff
 *   13     sp not 16-byte aligned at post-switch resume
 *   14..23 main-context x19..x28 poison lost (scheduler side)
 */

.data
.align 3
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
 * base_bit+0..9 into the mask at [shared+448]. Reloads shared itself;
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
    ldr  x10, [x9, #448]
    orr  x10, x10, x11
    str  x10, [x9, #448]
.endm

/* Int t8_run(Int stack_low [x0], Int stack_top [x1]) -> corruption bitmask
 * (0 = all preserved; -1 = probe's own malloc failed).
 * Callee-saved x19-x28 are poisoned/restored around this function for our
 * caller; all scheduler bookkeeping lives in memory, not across switches. */
.globl _t8_run
.extern _malloc
.extern _free
.extern _ms_context_init
.extern _ms_context_switch
.align 2
_t8_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!

    mov x20, x0                          /* stack_low */
    mov x22, x1                          /* stack_top */
    mov x0, #1024                        /* shared block size */
    bl  _malloc
    cbz x0, Lt8_run_fail
    adrp x16, g_shared@PAGE
    str x0, [x16, g_shared@PAGEOFF]      /* shared = malloc'd block */
    str xzr, [x0, #448]                  /* result = 0 */
    str x22, [x0, #456]                  /* informational */

    mov x19, x0                          /* x19 = shared (survives calls below) */

    /* self-capture main ctx (v3 lifecycle: arm shared+0 SUSPENDED before
     * anything switches OUT of it) -- ms_context_switch(shared+0, shared+0) */
    mov x0, x19
    mov x1, x19
    bl  _ms_context_switch

    /* ms_context_init(shared+224, stack_low, stack_size, t8_entry, shared) */
    add x0, x19, #224
    mov x1, x20                          /* stack_low */
    sub x2, x22, x20                     /* stack_size = stack_top - stack_low */
    adrp x3, _t8_entry@PAGE
    add  x3, x3, _t8_entry@PAGEOFF
    mov x4, x19                          /* userdata = shared */
    bl  _ms_context_init

    /* enter B; poison first so the main ctx saves poisoned state.
     * BUG FOUND WHILE WIRING THIS UP (not a compiler defect -- an assembly
     * logic error introduced while re-pointing this file): x19 is itself
     * one of the ten registers POISONALL clobbers, so "shared" can no
     * longer be read out of x19 after this point -- every use below
     * reloads it from g_shared instead, exactly as _t8_entry already does
     * throughout. Using x19 directly here (as a first draft of this
     * re-point briefly did) hands ms_context_switch a poison value as its
     * `from` pointer and SIGSEGVs on the first poisoned switch. */
    POISONALL
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]       /* from = main ctx (shared+0)   */
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    add  x1, x1, #224                      /* to   = b ctx     (shared+224) */
    bl  _ms_context_switch
Lt8_sched1:
    /* resumed after yield#1: poisons must have survived the round trip */
    CHKPOISONALL 14
    /* poison again and resume B: if the impl failed to save B's regs at
     * its yield, B sees this fresh poison instead of its magics */
    POISONALL
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    add  x1, x1, #224
    bl  _ms_context_switch
Lt8_sched2:
    CHKPOISONALL 14
    POISONALL
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    add  x1, x1, #224
    bl  _ms_context_switch
Lt8_sched3:
    CHKPOISONALL 14

    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x22, [x9, #448]                 /* mask (x22 free: already checked above) */
    mov  x0, x9
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
 * B-side entry. x0 = shared pointer (userdata, per ms_context_entry's
 * void(void*) contract).
 *
 * Register discipline: x19-x28 all carry magic payloads under test, so no
 * register value (incl. cached adrp results in x16/x17) may be assumed
 * valid across ms_context_switch; every global access reloads its own adrp.
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
    str  x10, [x0, #448]                 /* seed mask */

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

    /* ---- yield #1: from = B (+224), to = main (+0) ---- */
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    add  x0, x0, #224
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    bl   _ms_context_switch
Lt8_ret1:
    /* ---- resumed at RA(yield#1): lr must point exactly here ---- */
    adr  x14, Lt8_ret1
    cmp  x30, x14
    cset x10, ne
    lsl  x10, x10, #11
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x11, [x9, #448]
    orr  x11, x11, x10
    str  x11, [x9, #448]

    /* ---- yield #2 ---- */
    adrp x16, g_shared@PAGE
    ldr  x0, [x16, g_shared@PAGEOFF]
    add  x0, x0, #224
    adrp x16, g_shared@PAGE
    ldr  x1, [x16, g_shared@PAGEOFF]
    bl   _ms_context_switch
Lt8_ret2:
    /* ---- resumed at RA(yield#2): lr check for this site ---- */
    adr  x14, Lt8_ret2
    cmp  x30, x14
    cset x10, ne
    lsl  x10, x10, #11
    adrp x16, g_shared@PAGE
    ldr  x9, [x16, g_shared@PAGEOFF]
    ldr  x11, [x9, #448]
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
    str  x11, [x9, #448]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add  x0, x9, #224
    mov  x1, x9
    bl   _ms_context_switch

Lt8_entry_hang:                          /* unreachable */
    b    Lt8_entry_hang
