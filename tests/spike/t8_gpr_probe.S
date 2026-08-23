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
 * t8_run scenario: the scheduler side makes context B on the guarded stack
 * via ms_ctx_make and enters it with ms_ctx_switch. B's entry fills x19-x28
 * and fp(x29) with per-register magic values, yields, records lr, yields
 * again, then verifies every register after resume and finally switches back.
 * The scheduler keeps its own bookkeeping (x19/x20) across switches — if the
 * implementation drops callee-saved state on EITHER side this surfaces as a
 * nonzero mask or an outright fault.
 *
 * Bit map returned by t8_run:
 *   0..9   x19..x28 corrupted
 *   10     fp (x29) corrupted
 *   11     lr (x30) corrupted (checked at both resume sites)
 *   12     sp not 16-byte aligned at trampoline->entry handoff
 *   13     sp not 16-byte aligned at post-switch resume
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
 *   +0    main ctx save area (ms_ctx_t needs 104 bytes; slack included)
 *   +112  b ctx save area
 *   +224  corruption mask written by entry before final switch
 *   +232  initial SP (informational)
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

/* Int t8_run(Int top) -> corruption bitmask (0 = all preserved) */
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

    mov x20, x0                          /* top */
    mov x0, #1024                         /* shared block size */
    bl  _malloc
    cbz x0, Lt8_run_fail
    mov x19, x0                          /* shared; must survive switches */
    str xzr, [x19, #384]                 /* result = 0 */
    str x20, [x19, #392]                 /* informational */

    /* ms_ctx_make(shared+112, top, t8_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t8_entry@PAGE
    add  x2, x2, _t8_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* enter B; B runs until its first yield */
    mov x0, x19                          /* from = main ctx (shared+0)   */
    add x1, x19, #192                    /* to   = B ctx     (shared+192) */
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
    /* resumed after yield#1; resume B so it can record lr and yield again */
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15
    /* resumed after yield#2; resume B for the verification phase. B's final
     * switch lands here with the mask stored at shared+224. */
    mov x0, x19
    add x1, x19, #192
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    ldr x21, [x19, #384]                 /* mask */
    mov x0, x19
    bl  _free
    mov x0, x21

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
 * Register discipline: x19-x28 all carry magic payloads under test and libc
 * scratch registers cannot be assumed valid across ms_ctx_switch, so every
 * global access reloads its own adrp and nothing else is cached.
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

    /* ---- yield #1: from = B (+112), to = main (+0) ---- */
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

    /* store verdict */
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
