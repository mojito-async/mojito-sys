/*
 * t12_synth_probe.S — S0/M1.4-T12 probe: fresh synthetic-stack context
 * enters, exits through the defined completion path, and its stack is
 * reclaimable without corruption (aarch64, AAPCS64, Mach-O). RE-POINTED
 * (#128) at the PRODUCTION native/posix/ms_context_aarch64.S
 * `ms_context_switch`/`ms_context_init`, called directly (statically
 * linked, no dlsym indirection -- see t8_gpr_probe.S's header for the
 * full account).
 *
 * Scenario: ms_context_init a context whose entry writes known sentinel
 * patterns BOTH into a heap scratch area and into the region of its own
 * stack just below SP, records its SP, writes a completion marker, and
 * RETURNS. Per the v3 lifecycle (native/posix/ms_context_aarch64.S's
 * `mjs_ctx_trampoline`) the trampoline runs the context's finish hook (none
 * registered here), marks it FINISHED, and tail-switches to its recorded
 * `ret_to` (the context that last switched into it) -- so control lands
 * back in `_t12_run` right after the switch-in call, with B's stack still
 * intact below its recorded SP. The scheduler then verifies the completion
 * marker and every sentinel (stack canaries are read absolutely via B's
 * recorded SP, proving the stack was neither moved nor scribbled by the
 * completion path).
 *
 * The equal-size free/realloc reclaim half of the original S0 probe (a
 * `t12_reclaim` C-ABI entry calling the spike's own ms_stack_alloc/
 * ms_stack_free) is NOT reproduced here: NativeStack owns that same
 * alloc/free pair itself now, so t12_synthetic_stack.mojo proves reclaim
 * directly (drop the first NativeStack, create a fresh same-size one,
 * touch its top byte) rather than through a second C entry point. See
 * that driver's header for why.
 *
 * Exported:
 *   Int   t12_run(Int stack_low, Int stack_top)  verdict bitmask from
 *                                                 inside the scenario
 *
 * Bit map returned by t12_run:
 *   0..7   heap scratch sentinel k (shared+576+8k) corrupted
 *   8..15  own-stack sentinel k ([entry_sp-64+8k]) corrupted
 *   16     entry did not record its sp
 *   17     sp not 16-byte aligned at trampoline->entry handoff
 *   18     completion marker missing/wrong (completion path not exercised)
 */

.data
.align 3
/* shared block handed to the synthetic context (malloc'd by t12_run):
 *   +0    main ctx save area (224 reserved)
 *   +224  b ctx save area
 *   +448  mask / alignment seed
 *   +496  entry-recorded SP
 *   +504  completion marker
 *   +576  heap scratch: 64 bytes of sentinels
 */
g_shared:    .quad 0

.text
.align 2

/* T12CHKH/T12CHKS/T12HEAP/T12STACK k — one sentinel write or check per
 * invocation.
 *
 * MUST be GNU `.macro`s (one instruction per line), NOT C-preprocessor
 * `#define`s with `;`-joined instructions on one logical line: found
 * while mutation-testing this probe (deliberately breaking a sentinel
 * write and confirming the test catches it, per repo convention) that
 * Apple's clang integrated assembler treats `;` as an END-OF-LINE COMMENT
 * character for this target, not a statement separator. A `#define`
 * whose body joins several instructions with `;` therefore silently
 * assembles to ONLY ITS FIRST INSTRUCTION per invocation -- the rest is
 * treated as a comment and discarded, with NO error or warning from
 * either cpp or the assembler. The original `#define`-based versions of
 * these four also used a bare `#k` (immediate syntax) inside the macro
 * body, which the C preprocessor's stringification operator interprets
 * as "stringify parameter k" instead -- turning `lsl x10, x10, #k` into
 * `lsl x10, x10, "3"`, a second independent way the same construction was
 * broken. Together these made T12's heap-scratch and own-stack sentinel
 * checks (bits 0..15) vacuous -- they could never trip regardless of real
 * corruption -- before this fix; see the PR body and mojito-sys#205 for
 * the full account. */
.macro T12CHKH k
    movz x9, #(0x5E12)
    movk x9, #(\k), lsl #48
    movk x9, #(\k), lsl #0
    ldr  x10, [x19, #(576 + \k*8)]
    cmp  x10, x9
    cset x10, ne
    lsl  x10, x10, #\k
    orr  x11, x11, x10
.endm

.macro T12CHKS k
    movz x9, #(0x5E50)
    movk x9, #(\k), lsl #48
    ldr  x14, [x19, #496]
    ldr  x10, [x14, #(-64 + \k*8)]
    cmp  x10, x9
    cset x10, ne
    lsl  x10, x10, #(8+\k)
    orr  x11, x11, x10
.endm

.macro T12HEAP k
    movz x9, #(0x5E12)
    movk x9, #(\k), lsl #48
    movk x9, #(\k), lsl #0
    str  x9, [x19, #(576 + \k*8)]
.endm

.macro T12STACK k
    movz x9, #(0x5E50)
    movk x9, #(\k), lsl #48
    str  x9, [sp, #(-64 + \k*8)]
.endm

/* Int t12_run(Int stack_low [x0], Int stack_top [x1]) -> verdict bitmask
 * (0 = clean enter/exit). */
.globl _t12_run
.extern _malloc
.extern _free
.extern _ms_context_init
.extern _ms_context_switch
.align 2
_t12_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!

    mov x20, x0                          /* stack_low */
    mov x22, x1                          /* stack_top */
    mov x0, #1024
    bl  _malloc
    cbz x0, Lt12_run_fail
    mov x19, x0                          /* shared */
    str xzr, [x19, #448]

    /* self-capture main ctx (v3 lifecycle) */
    mov x0, x19
    mov x1, x19
    bl  _ms_context_switch

    /* ms_context_init(shared+224, stack_low, stack_size, t12_entry, shared) */
    add x0, x19, #224
    mov x1, x20
    sub x2, x22, x20
    adrp x3, _t12_entry@PAGE
    add  x3, x3, _t12_entry@PAGEOFF
    mov x4, x19
    bl  _ms_context_init

    /* Enter B. The entry plants its evidence and then RETURNS; the v3
     * trampoline tail-switches back to the context that switched it in
     * (recorded as ret_to), so control lands right here with B's stack
     * still intact below its recorded SP. */
    mov x0, x19                          /* from = main ctx */
    add x1, x19, #224                    /* to   = b ctx    */
    bl  _ms_context_switch

    /* ---- landed back on the scheduler side: verify everything ---- */
    mov x11, xzr

    /* completion marker -> bit 18 (entry must have completed cleanly) */
    ldr x9, [x19, #504]
    movz x10, #0xDE12
    movk x10, #0x5EC0, lsl #16
    cmp x9, x10
    cset x10, ne
    lsl x10, x10, #18
    orr x11, x11, x10

    /* heap scratch -> bits 0..7 */
    T12CHKH 0
    T12CHKH 1
    T12CHKH 2
    T12CHKH 3
    T12CHKH 4
    T12CHKH 5
    T12CHKH 6
    T12CHKH 7

    /* own-stack sentinels, read ABSOLUTELY via B's recorded SP -> bits
     * 8..15. Reading them after the context has exited proves the stack
     * memory was neither moved nor scribbled by the completion path. */
    T12CHKS 0
    T12CHKS 1
    T12CHKS 2
    T12CHKS 3
    T12CHKS 4
    T12CHKS 5
    T12CHKS 6
    T12CHKS 7

    /* recorded SP must be plausible (nonzero) -> bit 16 */
    ldr x9, [x19, #496]
    cbnz x9, Lt12_sp_ok
    orr x11, x11, #16
Lt12_sp_ok:

    str x11, [x19, #448]

    ldr x21, [x19, #448]
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
    str x10, [x19, #448]

    /* remember SP so the scheduler can inspect our stack absolutely */
    mov x14, sp
    str x14, [x19, #496]

    /* heap scratch sentinels at shared+576 .. shared+632 */
    T12HEAP 0
    T12HEAP 1
    T12HEAP 2
    T12HEAP 3
    T12HEAP 4
    T12HEAP 5
    T12HEAP 6
    T12HEAP 7

    /* own-stack sentinels just below current SP: [sp-64] .. [sp-8].
     * Below-SP memory on our own non-moving stack is unused scratch until
     * we fill it; nothing else may touch these bytes while the context is
     * suspended or after it exits. */
    T12STACK 0
    T12STACK 1
    T12STACK 2
    T12STACK 3
    T12STACK 4
    T12STACK 5
    T12STACK 6
    T12STACK 7

    /* completion marker: written last, checked by the scheduler */
    movz x9, #0xDE12
    movk x9, #0x5EC0, lsl #16
    str x9, [x19, #504]

    ret                                  /* completion path */
