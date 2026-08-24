/*
 * t10_align_probe.S — S0-T10 probe: stack alignment at trampoline entry,
 * across switches (aarch64, AAPCS64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Built and resolved exactly like
 * t8_gpr_probe.S: no link-time spike references; runtime dlsym after the
 * Mojo driver dlopen()s libmojito_spike.dylib.
 *
 * Contract requires sp to be 16-byte aligned at the ms_ctx_make trampoline
 * entry and stable AAPCS alignment after repeated switches. This probe
 * records the exact hardware SP inside the synthetic context at entry and
 * again after a suspend/resume round trip, exposes both values to the Mojo
 * driver via getters, and returns a bitmask verdict. The driver additionally
 * checks 16-byte frame alignment of freshly entered Mojo functions in its
 * own (scheduler) context — see t10_stack_alignment.mojo.
 *
 * Exported:
 *   Int32 t10_init(void)        0 = every required symbol resolved
 *   Int   t10_alloc(Int bytes)  -> initial SP of fresh guarded stack (0 = fail)
 *   void  t10_free(void)
 *   Int   t10_run(Int top)      verdict bitmask; 0 = all good
 *   Int   t10_entry_sp(void)    exact SP observed at trampoline->entry handoff
 *   Int   t10_resume_sp(void)   exact SP observed at post-switch resume
 *
 * Bit map returned by t10_run:
 *   0   sp misaligned (mod 16) at entry
 *   1   sp misaligned (mod 16) after resume
 *   2   sp changed across the yield/resume round trip on the same stack
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
g_entry_sp:  .quad 0
g_resume_sp: .quad 0
/* shared block: +0 main ctx (168B), +192 b ctx, +384 mask */
g_shared:    .quad 0

.text
.align 2

.globl _t10_init
.extern _dlsym
_t10_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #-2
    adrp x1, Lsym_alloc@PAGE
    add  x1, x1, Lsym_alloc@PAGEOFF
    bl  _dlsym
    adrp x9, g_alloc@PAGE
    str x0, [x9, g_alloc@PAGEOFF]
    cbz x0, Lt10_missing
    mov x0, #-2
    adrp x1, Lsym_free@PAGE
    add  x1, x1, Lsym_free@PAGEOFF
    bl  _dlsym
    adrp x9, g_free@PAGE
    str x0, [x9, g_free@PAGEOFF]
    cbz x0, Lt10_missing
    mov x0, #-2
    adrp x1, Lsym_make@PAGE
    add  x1, x1, Lsym_make@PAGEOFF
    bl  _dlsym
    adrp x9, g_make@PAGE
    str x0, [x9, g_make@PAGEOFF]
    cbz x0, Lt10_missing
    mov x0, #-2
    adrp x1, Lsym_switch@PAGE
    add  x1, x1, Lsym_switch@PAGEOFF
    bl  _dlsym
    adrp x9, g_switch@PAGE
    str x0, [x9, g_switch@PAGEOFF]
    cbz x0, Lt10_missing
    mov w0, #0
    b   Lt10_init_done
Lt10_missing:
    mov w0, #1
Lt10_init_done:
    ldp x29, x30, [sp], #16
    ret

.globl _t10_alloc
_t10_alloc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]
    adrp x9, g_base@PAGE
    add x1, x9, g_base@PAGEOFF
    adrp x9, g_top@PAGE
    add x2, x9, g_top@PAGEOFF
    blr x15
    cbz w0, Lt10_alloc_ok
    mov x0, #0
    b   Lt10_alloc_done
Lt10_alloc_ok:
    adrp x9, g_top@PAGE
    ldr x0, [x9, g_top@PAGEOFF]
Lt10_alloc_done:
    ldp x29, x30, [sp], #16
    ret

.globl _t10_free
_t10_free:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15
    ldp x29, x30, [sp], #16
    ret

.globl _t10_run
.extern _malloc
.extern _free
.align 2
_t10_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt10_run_fail
    mov x19, x0
    str xzr, [x19, #384]

    /* ms_ctx_make(shared+112, top, t10_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t10_entry@PAGE
    add  x2, x2, _t10_entry@PAGEOFF
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
    str x10, [x19, #384]

    /* ---- yield ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- resumed: record SP, compare with entry ---- */
    mov x14, sp
    adrp x16, g_resume_sp@PAGE
    str x14, [x16, g_resume_sp@PAGEOFF]
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #1                    /* bit 1 */
    ldr x11, [x19, #384]
    orr x11, x11, x10
    adrp x16, g_entry_sp@PAGE
    ldr x9, [x16, g_entry_sp@PAGEOFF]
    cmp x14, x9
    cset x10, ne
    lsl x10, x10, #2                    /* bit 2: SP changed across round trip */
    orr x11, x11, x10
    str x11, [x19, #384]

    /* ---- final switch back to the scheduler (never returns here) ---- */
    add x0, x19, #192
    mov x1, x19
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

Lt10_entry_hang:                        /* unreachable */
    b   Lt10_entry_hang
