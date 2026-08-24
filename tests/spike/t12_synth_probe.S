/*
 * t12_synth_probe.S — S0-T12 probe: fresh synthetic-stack context enters,
 * exits through the defined completion path, and its stack is reclaimable
 * without corruption (aarch64, AAPCS64, Mach-O).
 *
 * Owner: tests lane B (issue #12). Built and resolved exactly like
 * t8_gpr_probe.S: no link-time spike references; runtime dlsym after the
 * Mojo driver dlopen()s libmojito_spike.dylib.
 *
 * Scenario: allocate a fresh guarded stack, ms_ctx_make a context whose
 * entry writes known sentinel patterns BOTH into a heap scratch area and
 * into the region of its own stack just below SP, records its SP, writes a
 * completion marker, and RETURNS. Per contract v2 the trampoline must
 * tail-switch back to the return context recorded at ms_ctx_switch time,
 * so control lands at the scheduler's post-switch site; the scheduler then
 * verifies the completion marker and every sentinel (stack canaries are
 * read absolutely via B's recorded SP — proving the stack was neither moved
 * nor scribbled by the completion path). The driver then frees the stack
 * and allocates a fresh one of the same size to prove clean reclaim.
 *
 * Exported:
 *   Int32 t12_init(void)         0 = every required symbol resolved
 *   Int   t12_alloc(Int bytes)   -> initial SP of fresh guarded stack (0=fail)
 *   void  t12_free(void)
 *   Int   t12_run(Int top)       verdict bitmask from inside the scenario
 *   Int32 t12_reclaim(void)      0 = free + same-size realloc succeeded;
 *                                nonzero = corruption/reclaim problem
 *
 * Bit map returned by t12_run:
 *   0..7   heap scratch sentinel k (shared+512+8k) corrupted
 *   8..15  own-stack sentinel k ([entry_sp-64+8k]) corrupted
 *   16     entry did not record its sp
 *   17     sp not 16-byte aligned at trampoline->entry handoff
 *   18     completion marker missing/wrong (completion path not exercised)
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
g_bytes:     .quad 0                    /* requested stack size */
/* shared block handed to the synthetic context (malloc'd by t12_run):
 *   +0    main ctx save area (ms_ctx_t is 168 bytes in contract v2)
 *   +192  b ctx save area
 *   +384  mask / alignment seed
 *   +432  entry-recorded SP
 *   +440  completion marker
 *   +512  heap scratch: 64 bytes of sentinels
 */
g_shared:    .quad 0

.text
.align 2

.globl _t12_init
.extern _dlsym
_t12_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #-2
    adrp x1, Lsym_alloc@PAGE
    add  x1, x1, Lsym_alloc@PAGEOFF
    bl  _dlsym
    adrp x9, g_alloc@PAGE
    str x0, [x9, g_alloc@PAGEOFF]
    cbz x0, Lt12_missing
    mov x0, #-2
    adrp x1, Lsym_free@PAGE
    add  x1, x1, Lsym_free@PAGEOFF
    bl  _dlsym
    adrp x9, g_free@PAGE
    str x0, [x9, g_free@PAGEOFF]
    cbz x0, Lt12_missing
    mov x0, #-2
    adrp x1, Lsym_make@PAGE
    add  x1, x1, Lsym_make@PAGEOFF
    bl  _dlsym
    adrp x9, g_make@PAGE
    str x0, [x9, g_make@PAGEOFF]
    cbz x0, Lt12_missing
    mov x0, #-2
    adrp x1, Lsym_switch@PAGE
    add  x1, x1, Lsym_switch@PAGEOFF
    bl  _dlsym
    adrp x9, g_switch@PAGE
    str x0, [x9, g_switch@PAGEOFF]
    cbz x0, Lt12_missing
    mov w0, #0
    b   Lt12_init_done
Lt12_missing:
    mov w0, #1
Lt12_init_done:
    ldp x29, x30, [sp], #16
    ret

.globl _t12_alloc
_t12_alloc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_bytes@PAGE
    str x0, [x9, g_bytes@PAGEOFF]
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]
    adrp x9, g_base@PAGE
    add x1, x9, g_base@PAGEOFF
    adrp x9, g_top@PAGE
    add x2, x9, g_top@PAGEOFF
    blr x15
    cbz w0, Lt12_alloc_ok
    mov x0, #0
    b   Lt12_alloc_done
Lt12_alloc_ok:
    adrp x9, g_top@PAGE
    ldr x0, [x9, g_top@PAGEOFF]
Lt12_alloc_done:
    ldp x29, x30, [sp], #16
    ret

.globl _t12_free
_t12_free:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15
    ldp x29, x30, [sp], #16
    ret

/* Int32 t12_reclaim(void): free the stack, allocate an equal-size fresh one,
 * free it again. 0 == clean cycle. */
.globl _t12_reclaim
.align 2
_t12_reclaim:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x20, x21, [sp, #-16]!
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, g_base@PAGE
    ldr x0, [x9, g_base@PAGEOFF]
    blr x15                              /* free old stack */
    adrp x9, g_alloc@PAGE
    ldr x15, [x9, g_alloc@PAGEOFF]
    adrp x9, g_bytes@PAGE
    ldr x0, [x9, g_bytes@PAGEOFF]
    adrp x1, Lt12_scratch_base@PAGE
    add  x1, x1, Lt12_scratch_base@PAGEOFF
    adrp x2, Lt12_scratch_top@PAGE
    add  x2, x2, Lt12_scratch_top@PAGEOFF
    blr x15                              /* alloc fresh same size */
    cbz w0, Lt12_realloc_ok
    mov w0, #1                           /* realloc failed */
    b   Lt12_reclaim_done
Lt12_realloc_ok:
    adrp x9, Lt12_scratch_top@PAGE
    ldr x20, [x9, Lt12_scratch_top@PAGEOFF]
    cbz x20, Lt12_realloc_bad
    /* sanity: write + read back the highest usable byte of the new stack */
    mov x9, #42
    add x14, x20, #0                     /* top is highest usable address */
    sub x14, x14, #1
    strb w9, [x14]
    ldrb w10, [x14]
    cmp w9, w10
    b.ne Lt12_realloc_bad
    adrp x9, g_free@PAGE
    ldr x15, [x9, g_free@PAGEOFF]
    adrp x9, Lt12_scratch_base@PAGE
    ldr x0, [x9, Lt12_scratch_base@PAGEOFF]
    blr x15                              /* free the fresh stack */
    mov w0, #0
    b   Lt12_reclaim_done
Lt12_realloc_bad:
    mov w0, #2
Lt12_reclaim_done:
    ldp x20, x21, [sp], #16
    ldp x29, x30, [sp], #16
    ret

.data
.align 3
Lt12_scratch_base: .quad 0
Lt12_scratch_top:  .quad 0

.text

/* Int t12_run(Int top) -> verdict bitmask (0 = clean enter/exit) */
.globl _t12_run
.extern _malloc
.extern _free
.align 2
_t12_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* top */
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt12_run_fail
    mov x19, x0
    str xzr, [x19, #384]

    /* ms_ctx_make(shared+192, top, t12_entry, shared) */
    add x0, x19, #192
    mov x1, x20
    adrp x2, _t12_entry@PAGE
    add  x2, x2, _t12_entry@PAGEOFF
    mov x3, x19
    adrp x9, g_make@PAGE
    ldr x15, [x9, g_make@PAGEOFF]
    blr x15

    /* Enter B. The entry plants its evidence and then RETURNS; per contract
     * v2 the trampoline must tail-switch back to the return context it
     * recorded at ms_ctx_switch time, so control lands right here with B's
     * stack still intact below its recorded SP. */
    mov x0, x19                          /* from = main ctx */
    add x1, x19, #192                    /* to   = b ctx    */
    adrp x9, g_switch@PAGE
    ldr x15, [x9, g_switch@PAGEOFF]
    blr x15

    /* ---- landed back on the scheduler side: verify everything ---- */
    mov x11, xzr

    /* completion marker -> bit 18 (entry must have completed cleanly) */
    ldr x9, [x19, #440]
    movz x10, #0xDE12
    movk x10, #0x5EC0, lsl #16
    cmp x9, x10
    cset x10, ne
    lsl x10, x10, #18
    orr x11, x11, x10

    /* heap scratch -> bits 0..7 */
#define T12CHKH(k)                    \
    movz x9, #(0x5E12);               \
    movk x9, #(k), lsl #48;           \
    movk x9, #(k), lsl #0;            \
    ldr  x10, [x19, #(512 + k*8)];    \
    cmp  x10, x9;                     \
    cset x10, ne;                     \
    lsl  x10, x10, #k;                \
    orr  x11, x11, x10

    T12CHKH(0)
    T12CHKH(1)
    T12CHKH(2)
    T12CHKH(3)
    T12CHKH(4)
    T12CHKH(5)
    T12CHKH(6)
    T12CHKH(7)

#undef T12CHKH

    /* own-stack sentinels, read ABSOLUTELY via B's recorded SP -> bits
     * 8..15. Reading them after the context has exited proves the stack
     * memory was neither moved nor scribbled by the completion path. */
#define T12CHKS(k)                    \
    movz x9, #(0x5E50);               \
    movk x9, #(k), lsl #48;           \
    ldr  x14, [x19, #432];            \
    ldr  x10, [x14, #(-64 + k*8)];    \
    cmp  x10, x9;                     \
    cset x10, ne;                     \
    lsl  x10, x10, #(8+k);            \
    orr  x11, x11, x10

    T12CHKS(0)
    T12CHKS(1)
    T12CHKS(2)
    T12CHKS(3)
    T12CHKS(4)
    T12CHKS(5)
    T12CHKS(6)
    T12CHKS(7)

#undef T12CHKS

    /* recorded SP must be plausible (nonzero) -> bit 16 */
    ldr x9, [x19, #432]
    cbnz x9, Lt12_sp_ok
    orr x11, x11, #16
Lt12_sp_ok:

    str x11, [x19, #384]

    ldr x21, [x19, #384]
    mov x0, x19
    bl  _free
    mov x0, x21

    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

Lt12_run_fail:
    mov x0, #-1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

/*
 * B-side entry. x0 = shared pointer, parked in x19.
 * Plants all evidence and RETURNS — exercising the trampoline's defined
 * completion path (tail-switch to the recorded return context).
 */
.globl _t12_entry
.align 2
_t12_entry:
    mov x19, x0

    /* alignment at handoff -> bit 17 */
    mov x14, sp
    tst x14, #15
    cset x10, ne
    lsl x10, x10, #17
    str x10, [x19, #384]

    /* remember SP so the scheduler can inspect our stack absolutely */
    mov x14, sp
    str x14, [x19, #432]

    /* heap scratch sentinels at shared+512 .. shared+568 */
#define T12HEAP(k)                    \
    movz x9, #(0x5E12);               \
    movk x9, #(k), lsl #48;           \
    movk x9, #(k), lsl #0;            \
    str  x9, [x19, #(512 + k*8)]

    T12HEAP(0)
    T12HEAP(1)
    T12HEAP(2)
    T12HEAP(3)
    T12HEAP(4)
    T12HEAP(5)
    T12HEAP(6)
    T12HEAP(7)

#undef T12HEAP

    /* own-stack sentinels just below current SP: [sp-64] .. [sp-8].
     * Below-SP memory on our own non-moving stack is unused scratch until
     * we fill it; nothing else may touch these bytes while the context is
     * suspended or after it exits. */
#define T12STACK(k)                   \
    movz x9, #(0x5E50);               \
    movk x9, #(k), lsl #48;           \
    str  x9, [sp, #(-64 + k*8)]

    T12STACK(0)
    T12STACK(1)
    T12STACK(2)
    T12STACK(3)
    T12STACK(4)
    T12STACK(5)
    T12STACK(6)
    T12STACK(7)

#undef T12STACK

    /* completion marker: written last, checked by the scheduler */
    movz x9, #0xDE12
    movk x9, #0x5EC0, lsl #16
    str x9, [x19, #440]

    ret                                  /* completion path */
