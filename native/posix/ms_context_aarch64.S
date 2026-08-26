/*
 * ms_context_aarch64.S — register-level backend for the frozen ms_context
 * v2 C ABI (issue #64, spec §20.2); AAPCS64, Apple arm64 Mach-O.
 *
 * Ported verbatim-in-structure from the panel-proven spike
 * spike/context_switch/aarch64_switch.S (5/5 APPROVE after amendment #19),
 * renamed to the frozen ABI. ELF/production hardening (bti c, PAC notes,
 * sentinel promotion) lands with S5.2 (issue #65).
 *
 * Frozen v2 layout (pinned by _Static_asserts in ms_context.c):
 *   regs[0..11] @   0..88 => x19..x30 (slot i => x(19+i); [10]=fp, [11]=lr)
 *   fps[0..7]   @  96..159 => low 64 bits of v8..v15 (d8..d15)
 *   sp          @ 160
 *
 * Rules honored here:
 *   - Callee-saved x19-x28, fp(x29), lr(x30), d8-d15, sp are saved/
 *     restored; nothing else. Only temporaries x15-x17 are used.
 *   - x18 is NEVER written (platform register, reserved on Apple).
 *
 * Exit-trampoline design: a context made by mjs__ctx_make_raw starts on a
 * trampoline that records its own context pointer on its (fresh) stack,
 * calls entry(userdata) with the 16-byte-aligned sp, and on return
 * tail-switches back to its most recent switcher. Bookkeeping is the
 * spike's single-threaded global resume table (_mjs_resume_tab) plus
 * _ms_last_from/_ms_last_to; S5.3 (#66) replaces it with per-context
 * lifecycle state without changing this frozen ABI.
 */

#if !defined(__APPLE__)
#error "ms_context_aarch64.S targets Apple arm64 (Mach-O) only; ELF lands with S5.2 (issue #65)"
#endif

/* PAC/BTI limitation (recorded in the spike, unchanged here): built with
 * default arm64 codegen — unsigned return addresses, no BTI landing pads.
 * Entry-point bti c / pacibsp pairing is S5.2 scope. */

.section __TEXT,__text,regular,pure_instructions

/* ---- bookkeeping (single-threaded until S5.3) -------------------------- */
.private_extern _ms_last_from
.zerofill __DATA,__common,_ms_last_from,8,3
.private_extern _ms_last_to
.zerofill __DATA,__common,_ms_last_to,8,3
.private_extern _mjs_resume_tab
.zerofill __DATA,__common,_mjs_resume_tab,1024,3   /* 64 entries x {ctx,ret} */

.set MS_CTX_FPS_OFF, 96
.set MS_CTX_SP_OFF, 160

/* ------------------------------------------------------------------------ */
/* void ms_context_switch(ms_context *from [x0], ms_context *to [x1])        */
/* Saves current callee-saved state into *from; resumes *to. A zeroed sp     */
/* slot in *to (destroyed/never-initialized context) traps loudly instead    */
/* of jumping through garbage.                                               */
/* ------------------------------------------------------------------------ */
.align 4
.globl _ms_context_switch
_ms_context_switch:
        /* Save callee-saved GPRs + fp/lr into from->regs[0..11]. The
         * save happens FIRST so that capture-as-self-switch
         * (from == to, fresh zero-filled storage) becomes live here:
         * filling sp makes the destroyed-target guard below pass. */
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

        /* destroyed/never-initialized target (sp slot 0): trap loudly
         * instead of jumping through garbage. Checked AFTER the save so
         * ms_context_capture(ctx) (self-switch on fresh storage) works. */
        ldr     x16, [x1, #MS_CTX_SP_OFF]
        cbz     x16, 7f

        /* _mjs_resume_tab[to] = from  (most recent switcher of `to`) */
        adrp    x16, _mjs_resume_tab@PAGE
        add     x16, x16, _mjs_resume_tab@PAGEOFF
        mov     x17, #64
1:      ldr     x15, [x16]
        cbz     x15, 2f                         /* empty slot */
        cmp     x15, x1
        b.eq    2f                              /* existing row */
        add     x16, x16, #16
        subs    x17, x17, #1
        b.ne    1b
        brk     #0x67                           /* table full: trap loudly */

2:      str     x1, [x16]
        str     x0, [x16, #8]

        adrp    x16, _ms_last_from@PAGE
        str     x0, [x16, _ms_last_from@PAGEOFF]
        adrp    x16, _ms_last_to@PAGE
        str     x1, [x16, _ms_last_to@PAGEOFF]

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

7:      brk     #0x68                           /* resume of dead context */

/* ------------------------------------------------------------------------ */
/* void mjs__ctx_make_raw(ms_context *ctx [x0], void *stack_top [x1],        */
/*                        ms_context_entry entry [x2],                       */
/*                        void *userdata [x3])                               */
/* Dylib-private helper behind ms_context_init's validation. Synthesizes a   */
/* resumed state: first switch lands on the exit trampoline with             */
/* sp == stack_top (16-aligned; misalignment traps).                         */
/* ------------------------------------------------------------------------ */
.align 4
.private_extern _mjs__ctx_make_raw
_mjs__ctx_make_raw:
        tst     x1, #15
        b.ne    3f                              /* stack_top misaligned */
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
        str     x1, [x0, #MS_CTX_SP_OFF]        /* sp = stack_top */
        adrp    x16, _mjs_ctx_trampoline@PAGE
        add     x16, x16, _mjs_ctx_trampoline@PAGEOFF
        str     x16, [x0, #88]                  /* lr = trampoline */
        ret
3:      brk     #0x64                           /* stack_top not 16-aligned */

/* ------------------------------------------------------------------------ */
/* Exit trampoline (private): entered via ms_context_switch `ret` with       */
/*   x19 = entry, x20 = userdata, sp = stack_top (16-aligned).               */
/* Calls entry(userdata); on return switches back to the most recent         */
/* switcher. Resuming an already-exited context traps.                       */
/* ------------------------------------------------------------------------ */
.align 4
.private_extern _mjs_ctx_trampoline
_mjs_ctx_trampoline:
        sub     sp, sp, #16                     /* slot for self, below entry frames */
        adrp    x15, _ms_last_to@PAGE
        ldr     x15, [x15, _ms_last_to@PAGEOFF] /* self (valid on first entry) */
        str     x15, [sp]

        mov     x0, x20
        blr     x19                             /* entry(userdata) */

        /* self = stashed pointer; return_to = _mjs_resume_tab[self] */
        ldr     x0, [sp]
        add     sp, sp, #16
        adrp    x16, _mjs_resume_tab@PAGE
        add     x16, x16, _mjs_resume_tab@PAGEOFF
        mov     x17, #64
4:      ldr     x15, [x16]
        cmp     x15, x0
        b.eq    5f
        add     x16, x16, #16
        subs    x17, x17, #1
        b.ne    4b
        brk     #0x65                           /* unknown self: impossible */
5:      ldr     x1, [x16, #8]                   /* x0 = self, x1 = return_to */

        adr     x17, 6f
        mov     x30, x17                        /* re-resume after exit traps */
        b       _ms_context_switch              /* tail call: switch(self, return_to) */
6:      brk     #0x66
