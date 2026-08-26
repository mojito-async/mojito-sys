/*
 * ms_context_aarch64.S — register-level backend for the frozen ms_context
 * v2 C ABI (issue #64, spec §20.2); AAPCS64, Darwin Mach-O AND Linux ELF
 * (issue #65; spec §21 orders "AArch64 Darwin/Linux" first).
 *
 * Ported verbatim-in-structure from the panel-proven spike
 * spike/context_switch/aarch64_switch.S (5/5 APPROVE after amendment #19),
 * renamed to the frozen ABI.
 *
 * ONE skeleton, two ABIs: the instruction bodies below are shared
 * verbatim and only symbol naming / addressing / section directives go
 * through the MS_* preprocessor macros:
 *   __APPLE__ (Mach-O): underscore-prefixed symbols, @PAGE/@PAGEOFF
 *     addressing, private_extern internals;
 *   __ELF__   (Linux): unprefixed symbols, :lo12 relocations, .hidden
 *     internals, plus .type/%function and .size on every function
 *     (spec §21 unwind/debug metadata where practical — no .eh_frame for
 *     hand-written asm: the synthetic trampoline has no C frame to
 *     describe).
 *
 * S5.3 (#66): SELF-CONTAINED CONTEXT LIFECYCLE. The spike's global
 * return-to bookkeeping (the 64-entry _mjs_resume_tab plus
 * _ms_last_from/_ms_last_to) is DELETED. Every context record now owns
 * its own state machine and its own return target in a v3 lifecycle tail
 * appended after the 168-byte frozen v2 save area (prefix-stable: all v2
 * offsets are unchanged):
 *
 *   state    @168  DEAD=0 | EMPTY=1 | RUNNING=2 | SUSPENDED=3 |
 *                  FINISHED=4 (mirrored by MS_CTX_STATE_* below)
 *   ret_to   @176  most recent switcher of this context (NULL until the
 *                  first resume; read by the trampoline's completion pass)
 *   finish_cb/finish_ud @184/@192  completion hook registered via
 *                  ms_context_set_finish_hook
 *
 * No shared mutable state remains anywhere in the backend — no global
 * table, no capacity limit (unbounded live contexts), and distinct
 * contexts are fully thread-independent (per-context exclusivity is the
 * CALLER's obligation, per the s5-ctx header block).
 *
 * Hardening (issue #65): every entry point starts with `bti c` — hint-
 * space NOP where BTI is not enforced; mandatory for _mjs_ctx_trampoline,
 * which is reached by an INDIRECT branch (the restored lr), and kept on
 * the direct-called entry points for uniformity.
 *
 * PAC limitation (S0 spike limitation folded here, DEFERRED — NOT fixed):
 * built with default arm64 codegen — return addresses are UNSIGNED and
 * pacibsp/autiasp pairing is absent. Under arm64e/PAC enforcement the
 * saved lr would be signed per-frame and plain restore-and-ret would
 * fault; pairing also requires every downstream frame (Mojo AOT) built
 * with matching PAC. Recorded as an explicit limitation.
 *
 * Save-area layout (v2 prefix pinned by _Static_asserts in ms_context.c):
 *   regs[0..11] @   0..88 => x19..x30 (slot i => x(19+i); [10]=fp, [11]=lr)
 *   fps[0..7]   @  96..159 => low 64 bits of v8..v15 (d8..d15)
 *   sp          @ 160
 *
 * Rules honored here:
 *   - Callee-saved x19-x28, fp(x29), lr(x30), d8-d15, sp are saved/
 *     restored; nothing else. Only temporaries x15-x17 are used.
 *   - x18 is NEVER written (platform register, reserved on Apple).
 *
 * Lifecycle traps (loud brk on GENUINE misuse only):
 *   #0x64  stack_top misaligned at make;
 *   #0x66  resume of a FINISHED context;
 *   #0x68  resume of DEAD storage (destroyed / never-initialized);
 *   #0x69  resume of a RUNNING context (concurrent re-resume);
 *   #0x6a  trampoline fall-through guard — control must NEVER fall
 *          through an invalid return address (spec §22 L1173): the
 *          completion pass tail-calls ms_context_switch unconditionally
 *          with lr aimed here.
 */

#if defined(__APPLE__)

#define MS_SYM(name)                 _##name
#define MS_PUB(name)                 .globl _##name
#define MS_PRIV(name)                .private_extern _##name
#define MS_TEXT                      .section __TEXT,__text,regular,pure_instructions
#define MS_ADRP(reg, name)           adrp reg, _##name@PAGE
#define MS_ADDLO(dst, base, name)    add dst, base, _##name@PAGEOFF
#define MS_TAIL(name)                b _##name

#elif defined(__ELF__)

#define MS_SYM(name)                 name
#define MS_PUB(name)                 .globl name ; .type name,%function
#define MS_PRIV(name)                .globl name ; .hidden name ; .type name,%function
#define MS_TEXT                      .section .text,"ax",%progbits
#define MS_ADRP(reg, name)           adrp reg, name
#define MS_ADDLO(dst, base, name)    add dst, base, :lo12:name
#define MS_TAIL(name)                b name

#else
#error "ms_context_aarch64.S requires __APPLE__ (Mach-O) or __ELF__ (Linux)"
#endif

#if defined(__APPLE__)
#define MS_FUNC_END(name)
#else
#define MS_FUNC_END(name)            .size name, .-name
#endif

MS_TEXT

/* v2 save-area offsets (frozen; pinned by _Static_asserts in ms_context.c) */
.set MS_CTX_FPS_OFF, 96
.set MS_CTX_SP_OFF, 160
/* v3 lifecycle tail (#66) */
.set MS_CTX_STATE_OFF, 168
.set MS_CTX_RETTO_OFF, 176
.set MS_CTX_FINCB_OFF, 184
.set MS_CTX_FINUD_OFF, 192

/* lifecycle states — MUST mirror the ms_ctx_state enum in ms_context.c */
.set MS_STATE_DEAD, 0
.set MS_STATE_EMPTY, 1
.set MS_STATE_RUNNING, 2
.set MS_STATE_SUSPENDED, 3
.set MS_STATE_FINISHED, 4

/* ------------------------------------------------------------------------ */
/* void ms_context_switch(ms_context *from [x0], ms_context *to [x1])        */
/* Saves current callee-saved state into *from; resumes *to. Each context    */
/* record carries its own lifecycle state + return target (#66). Loud traps  */
/* on genuine misuse: resume of DEAD/RUNNING/FINISHED targets.               */
/* ------------------------------------------------------------------------ */
.align 4
MS_PUB(ms_context_switch)
MS_SYM(ms_context_switch):
        bti     c                               /* BTI landing pad (#65) */
        /* Save callee-saved GPRs + fp/lr into from->regs[0..11]. The
         * save happens FIRST so that capture-as-self-switch
         * (from == to, fresh zero-filled storage) becomes live here:
         * filling sp makes the snapshot resumable. The state slot is
         * NOT part of the register save — capture explicitly re-arms
         * it on the self-switch path below (capture-revives-destroyed,
         * header F4 contract). */
        stp     x19, x20, [x0, #0]
        stp     x21, x22, [x0, #16]
        stp     x23, x24, [x0, #32]
        stp     x25, x26, [x0, #48]
        stp     x27, x28, [x0, #64]
        stp     x29, x30, [x0, #80]             /* fp, lr */
        /* save callee-saved FP/SIMD low halves d8-d15 into from->fps[0..7] */
        stp     d8, d9, [x0, #MS_CTX_FPS_OFF]
        stp     d10, d11, [x0, #(MS_CTX_FPS_OFF+16)]
        stp     d12, d13, [x0, #(MS_CTX_FPS_OFF+32)]
        stp     d14, d15, [x0, #(MS_CTX_FPS_OFF+48)]
        mov     x15, sp
        str     x15, [x0, #MS_CTX_SP_OFF]       /* sp saved last */

        cmp     x0, x1
        b.eq    5f                              /* self-switch: capture */

        /* Target validation (#66 per-record state machine). */
        ldr     x16, [x1, #MS_CTX_STATE_OFF]
        cbz     x16, 7f                         /* DEAD storage: trap */
        cmp     x16, #MS_STATE_RUNNING
        b.eq    8f                              /* re-resume RUNNING: trap */
        cmp     x16, #MS_STATE_FINISHED
        b.eq    6f                              /* re-resume FINISHED: trap */

        /* to->ret_to = from (most recent switcher of `to`) */
        str     x0, [x1, #MS_CTX_RETTO_OFF]

        /* from->state: RUNNING -> SUSPENDED. Conditional so the
         * trampoline's post-completion switch-out (from == FINISHED)
         * never demotes FINISHED. */
        ldr     x16, [x0, #MS_CTX_STATE_OFF]
        cmp     x16, #MS_STATE_RUNNING
        b.ne    1f
        mov     w16, #MS_STATE_SUSPENDED
        str     w16, [x0, #MS_CTX_STATE_OFF]
1:
        mov     w16, #MS_STATE_RUNNING
        str     w16, [x1, #MS_CTX_STATE_OFF]

        /* belt+suspenders: a zeroed sp slot in a non-DEAD target is
         * corruption — trap instead of jumping through garbage. */
        ldr     x15, [x1, #MS_CTX_SP_OFF]
        cbz     x15, 7f

        /* restore `to` */
        ldp     d14, d15, [x1, #(MS_CTX_FPS_OFF+48)]
        ldp     d12, d13, [x1, #(MS_CTX_FPS_OFF+32)]
        ldp     d10, d11, [x1, #(MS_CTX_FPS_OFF+16)]
        ldp     d8, d9, [x1, #MS_CTX_FPS_OFF]
        ldp     x27, x28, [x1, #64]
        ldp     x25, x26, [x1, #48]
        ldp     x23, x24, [x1, #32]
        ldp     x21, x22, [x1, #16]
        ldp     x19, x20, [x1, #0]
        ldr     x16, [x1, #MS_CTX_SP_OFF]
        mov     sp, x16
        ldp     x29, x30, [x1, #80]             /* fp, lr restored last */
        ret                                     /* br x30 semantics */

        /* Self-switch (ms_context_capture): the just-saved snapshot IS
         * the resumable state, so arm the record as SUSPENDED regardless
         * of its prior state — this REVIVES destroyed (DEAD) storage and
         * overwrites any live snapshot (header F4/capture contracts),
         * then resumes right here. */
5:      mov     w16, #MS_STATE_SUSPENDED
        str     w16, [x1, #MS_CTX_STATE_OFF]
        b       9f

6:      brk     #0x66                           /* resume of FINISHED ctx */
7:      brk     #0x68                           /* resume of DEAD/poisoned ctx */
8:      brk     #0x69                           /* re-resume of RUNNING ctx */

9:      /* shared restore epilogue for the self-switch path */
        ldp     d14, d15, [x1, #(MS_CTX_FPS_OFF+48)]
        ldp     d12, d13, [x1, #(MS_CTX_FPS_OFF+32)]
        ldp     d10, d11, [x1, #(MS_CTX_FPS_OFF+16)]
        ldp     d8, d9, [x1, #MS_CTX_FPS_OFF]
        ldp     x27, x28, [x1, #64]
        ldp     x25, x26, [x1, #48]
        ldp     x23, x24, [x1, #32]
        ldp     x21, x22, [x1, #16]
        ldp     x19, x20, [x1, #0]
        ldr     x16, [x1, #MS_CTX_SP_OFF]
        mov     sp, x16
        ldp     x29, x30, [x1, #80]
        ret
MS_FUNC_END(ms_context_switch)

/* ------------------------------------------------------------------------ */
/* void mjs__ctx_make_raw(ms_context *ctx [x0], void *stack_top [x1],        */
/*                        ms_context_entry entry [x2],                       */
/*                        void *userdata [x3])                               */
/* Dylib-private helper behind ms_context_init's validation. Synthesizes a   */
/* resumed state: first switch lands on the exit trampoline with             */
/* sp = stack_top - 16 (16-aligned; misalignment traps), where make has      */
/* parked the context's own pointer as the trampoline's self slot. Arms the  */
/* lifecycle tail: EMPTY, no return target, no finish hook (#66).            */
/* ------------------------------------------------------------------------ */
.align 4
MS_PRIV(mjs__ctx_make_raw)
MS_SYM(mjs__ctx_make_raw):
        bti     c                               /* BTI landing pad (#65) */
        tst     x1, #15
        b.ne    3f                              /* stack_top misaligned */
        sub     x15, x1, #16                    /* trampoline self-slot frame */
        str     x0, [x15]                       /* [frame] = self */
        str     x15, [x0, #MS_CTX_SP_OFF]       /* sp = stack_top - 16 */
        stp     x2, x3, [x0, #0]                /* x19 = entry, x20 = userdata */
        mov     x15, xzr
        stp     x15, x15, [x0, #16]             /* x21, x22 */
        stp     x15, x15, [x0, #32]             /* x23, x24 */
        stp     x15, x15, [x0, #48]             /* x25, x26 */
        stp     x15, x15, [x0, #64]             /* x27, x28 */
        str     x15, [x0, #80]                  /* fp = 0 */
        stp     x15, x15, [x0, #(MS_CTX_FPS_OFF)]      /* d8, d9 = 0 */
        stp     x15, x15, [x0, #(MS_CTX_FPS_OFF+16)]   /* d10, d11 = 0 */
        stp     x15, x15, [x0, #(MS_CTX_FPS_OFF+32)]   /* d12, d13 = 0 */
        stp     x15, x15, [x0, #(MS_CTX_FPS_OFF+48)]   /* d14, d15 = 0 */
        str     xzr, [x0, #MS_CTX_RETTO_OFF]    /* no return target yet */
        str     xzr, [x0, #MS_CTX_FINCB_OFF]    /* no finish hook yet */
        str     xzr, [x0, #MS_CTX_FINUD_OFF]
        mov     w15, #MS_STATE_EMPTY
        str     w15, [x0, #MS_CTX_STATE_OFF]    /* armed, never run */
        MS_ADRP(x16, mjs_ctx_trampoline)
        MS_ADDLO(x16, x16, mjs_ctx_trampoline)
        str     x16, [x0, #88]                  /* lr = trampoline */
        ret
3:      brk     #0x64                           /* stack_top not 16-aligned */
MS_FUNC_END(mjs__ctx_make_raw)

/* ------------------------------------------------------------------------ */
/* Exit trampoline (private): entered INDIRECTLY via ms_context_switch       */
/* `ret` with x19 = entry, x20 = userdata, sp = make's frame ([sp] = self).  */
/* Spec §22 flow (L1153-1173): calls entry(userdata) with userdata passed    */
/* through UNMODIFIED, runs the completion stage (finish hook exactly once, */
/* then state = FINISHED), then switches out PERMANENTLY to the context's    */
/* own recorded return target. The tail is an unconditional tail-call with   */
/* lr aimed at a brk guard — a synthetic stack never falls through an        */
/* invalid return address. Resuming an already-FINISHED context traps in     */
/* ms_context_switch (#0x66).                                                */
/* ------------------------------------------------------------------------ */
.align 4
MS_PRIV(mjs_ctx_trampoline)
MS_SYM(mjs_ctx_trampoline):
        bti     c                               /* indirect entry: needs BTI */
        ldr     x15, [sp]                       /* self from make's frame */
        sub     sp, sp, #16                     /* stash self below entry frames */
        str     x15, [sp]

        mov     x0, x20
        blr     x19                             /* entry(userdata) */

        /* Completion stage (#66): fire the registered finish hook EXACTLY
         * once — this pass runs once per context lifetime — before the
         * permanent switch-out. */
        ldr     x19, [sp]                       /* self */
        add     sp, sp, #16
        ldr     x16, [x19, #MS_CTX_FINCB_OFF]
        cbz     x16, 1f
        ldr     x0, [x19, #MS_CTX_FINUD_OFF]
        blr     x16                             /* finish_cb(finish_userdata) */
1:
        mov     w16, #MS_STATE_FINISHED
        str     w16, [x19, #MS_CTX_STATE_OFF]
        mov     x0, x19                         /* from = self */
        ldr     x1, [x19, #MS_CTX_RETTO_OFF]    /* to = permanent target */

        adr     x17, 2f
        mov     x30, x17                        /* impossible return lands here */
        MS_TAIL(ms_context_switch)              /* tail call: switch(self, ret_to) */
2:      brk     #0x6a                           /* never fall through (§22 L1173) */
MS_FUNC_END(mjs_ctx_trampoline)
