/*
 * t10_align_probe.S — S0/M1.4-T10 probe: stack alignment at trampoline
 * entry, across switches (aarch64, AAPCS64, Mach-O). RE-POINTED (#128) at
 * the PRODUCTION native/posix/ms_context_aarch64.S `ms_context_switch`/
 * `ms_context_init`, called directly (statically linked, no dlsym
 * indirection -- see t8_gpr_probe.S's header for the full account).
 *
 * Contract requires sp to be 16-byte aligned at the ms_context_init
 * trampoline entry and stable AAPCS alignment after repeated switches.
 * This probe records the exact hardware SP inside the synthetic context at
 * entry and again after a suspend/resume round trip, exposes both values
 * to the Mojo driver via getters, and returns a bitmask verdict. The
 * driver additionally checks 16-byte frame alignment of freshly entered
 * Mojo functions in its own (scheduler) context -- see
 * t10_stack_alignment.mojo.
 *
 * Exported:
 *   Int   t10_run(Int stack_low, Int stack_top)  verdict bitmask; 0 = good
 *   Int   t10_entry_sp(void)    exact SP observed at trampoline->entry handoff
 *   Int   t10_resume_sp(void)   exact SP observed at post-switch resume
 *
 * Bit map returned by t10_run:
 *   0   sp misaligned (mod 16) at entry
 *   1   sp misaligned (mod 16) after resume
 *   2   sp changed across the yield/resume round trip on the same stack
 */

.data
.align 3
g_entry_sp:  .quad 0
g_resume_sp: .quad 0
/* shared block: +0 main ctx (224 reserved), +224 b ctx, +448 mask */
g_shared:    .quad 0

.text
.align 2

.globl _t10_run
.extern _malloc
.extern _free
.extern _ms_context_init
.extern _ms_context_switch
.align 2
_t10_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0
    mov x22, x1
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt10_run_fail
    adrp x16, g_shared@PAGE
    str x0, [x16, g_shared@PAGEOFF]
    str xzr, [x0, #448]
    mov x19, x0                          /* shared */

    /* self-capture main ctx (v3 lifecycle) */
    mov x0, x19
    mov x1, x19
    bl  _ms_context_switch

    /* ms_context_init(shared+224, stack_low, stack_size, t10_entry, shared) */
    add x0, x19, #224
    mov x1, x20
    sub x2, x22, x20
    adrp x3, _t10_entry@PAGE
    add  x3, x3, _t10_entry@PAGEOFF
    mov x4, x19
    bl  _ms_context_init

    /* enter B; yield; resume; final switch lands here */
    mov x0, x19
    add x1, x19, #224
    bl  _ms_context_switch
    mov x0, x19
    add x1, x19, #224
    bl  _ms_context_switch

    ldr x21, [x19, #448]
    mov x0, x19
    bl  _free
    mov x0, x21

    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

Lt10_run_fail:
    mov x0, #-1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/* getters */
.globl _t10_entry_sp
_t10_entry_sp:
    adrp x8, g_entry_sp@PAGE
    ldr  x0, [x8, g_entry_sp@PAGEOFF]
    ret

.globl _t10_resume_sp
_t10_resume_sp:
    adrp x8, g_resume_sp@PAGE
    ldr  x0, [x8, g_resume_sp@PAGEOFF]
    ret

/* B-side entry. x0 = shared pointer, parked in x19. */
.globl _t10_entry
.align 2
_t10_entry:
    mov x19, x0

    /* exact SP at trampoline->entry handoff */
    mov x14, sp
    adrp x16, g_entry_sp@PAGE
    str x14, [x16, g_entry_sp@PAGEOFF]
    tst x14, #15
    cset x10, ne                        /* bit 0: misaligned */
    str x10, [x19, #448]

    /* ---- yield ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

    /* ---- resumed: record SP, compare with entry ---- */
    mov x14, sp
    adrp x16, g_resume_sp@PAGE
    str x14, [x16, g_resume_sp@PAGEOFF]
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #1                    /* bit 1 */
    ldr x11, [x19, #448]
    orr x11, x11, x10
    adrp x16, g_entry_sp@PAGE
    ldr x9, [x16, g_entry_sp@PAGEOFF]
    cmp x14, x9
    cset x10, ne
    lsl x10, x10, #2                    /* bit 2: SP changed across round trip */
    orr x11, x11, x10
    str x11, [x19, #448]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add x0, x19, #224
    mov x1, x19
    bl  _ms_context_switch

Lt10_entry_hang:                        /* unreachable */
    b   Lt10_entry_hang
