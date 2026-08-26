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
 *     addressing, private_extern internals, __DATA,__common zerofills;
 *   __ELF__   (Linux): unprefixed symbols, :lo12 relocations, .hidden
 *     internals (.local bookkeeping), .bss bookkeeping area, plus
 *     .type/%function and .size on every function (spec §21 unwind/debug
 *     metadata where practical — no .eh_frame for hand-written asm: the
 *     synthetic trampoline has no C frame to describe).
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
 * with matching PAC. Recorded as an explicit limitation, revisit with
 * S5.3/#66 lifecycle work.
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

#if defined(__APPLE__)

#define MS_SYM(name)                 _##name
#define MS_PUB(name)                 .globl _##name
#define MS_PRIV(name)                .private_extern _##name
#define MS_TEXT                      .section __TEXT,__text,regular,pure_instructions
#define MS_ADRP(reg, name)           adrp reg, _##name@PAGE
#define MS_ADDLO(dst, base, name)    add dst, base, _##name@PAGEOFF
#define MS_TAIL(name)                b _##name
/* zerofill align=3 => 8-byte; each directive MUST expand to its own line —
 * the Mach-O IAS does not honor a .zerofill after a `;` separator */
#define MS_ZEROFILL(name, bytes)     .zerofill __DATA,__common,_##name,bytes,3

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

.set MS_CTX_FPS_OFF, 96
.set MS_CTX_SP_OFF, 160

/* ---- bookkeeping (single-threaded until S5.3) -------------------------- */
#if defined(__APPLE__)
MS_PRIV(ms_last_from)
MS_ZEROFILL(ms_last_from, 8)
MS_PRIV(ms_last_to)
MS_ZEROFILL(ms_last_to, 8)
MS_PRIV(mjs_resume_tab)
MS_ZEROFILL(mjs_resume_tab, 1024)          /* 64 entries x {ctx,ret} */
#else
.section .bss,"aw",@nobits
.balign 8
.local ms_last_from
ms_last_from:
        .zero   8
.local ms_last_to
ms_last_to:
        .zero   8
.local mjs_resume_tab
mjs_resume_tab:
        .zero   1024                          /* 64 entries x {ctx,ret} */
MS_TEXT
#endif

/* ------------------------------------------------------------------------ */
/* void ms_context_switch(ms_context *from [x0], ms_context *to [x1])        */
/* Saves current callee-saved state into *from; resumes *to. A zeroed sp     */
/* slot in *to (destroyed/never-initialized context) traps loudly instead    */
/* of jumping through garbage.                                               */
/* ------------------------------------------------------------------------ */
.align 4
MS_PUB(ms_context_switch)
MS_SYM(ms_context_switch):
        bti     c                               /* BTI landing pad (#65) */
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

        /* mjs_resume_tab[to] = from  (most recent switcher of `to`) */
        MS_ADRP(x16, mjs_resume_tab)
        MS_ADDLO(x16, x16, mjs_resume_tab)
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

        MS_ADRP(x16, ms_last_from)
        MS_ADDLO(x16, x16, ms_last_from)
        str     x0, [x16]
        MS_ADRP(x16, ms_last_to)
        MS_ADDLO(x16, x16, ms_last_to)
        str     x1, [x16]

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
MS_FUNC_END(ms_context_switch)

/* ------------------------------------------------------------------------ */
/* void mjs__ctx_make_raw(ms_context *ctx [x0], void *stack_top [x1],        */
/*                        ms_context_entry entry [x2],                       */
/*                        void *userdata [x3])                               */
/* Dylib-private helper behind ms_context_init's validation. Synthesizes a   */
/* resumed state: first switch lands on the exit trampoline with             */
/* sp == stack_top (16-aligned; misalignment traps).                         */
/* ------------------------------------------------------------------------ */
.align 4
MS_PRIV(mjs__ctx_make_raw)
MS_SYM(mjs__ctx_make_raw):
        bti     c                               /* BTI landing pad (#65) */
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
        MS_ADRP(x16, mjs_ctx_trampoline)
        MS_ADDLO(x16, x16, mjs_ctx_trampoline)
        str     x16, [x0, #88]                  /* lr = trampoline */
        ret
3:      brk     #0x64                           /* stack_top not 16-aligned */
MS_FUNC_END(mjs__ctx_make_raw)

/* ------------------------------------------------------------------------ */
/* Exit trampoline (private): entered INDIRECTLY via ms_context_switch       */
/* `ret` with x19 = entry, x20 = userdata, sp = stack_top (16-aligned).      */
/* Calls entry(userdata); on return switches back to the most recent         */
/* switcher. Resuming an already-exited context traps.                       */
/* ------------------------------------------------------------------------ */
.align 4
MS_PRIV(mjs_ctx_trampoline)
MS_SYM(mjs_ctx_trampoline):
        bti     c                               /* indirect entry: needs BTI */
        sub     sp, sp, #16                     /* slot for self, below entry frames */
        MS_ADRP(x15, ms_last_to)
        MS_ADDLO(x15, x15, ms_last_to)
        ldr     x15, [x15]                      /* self (valid on first entry) */
        str     x15, [sp]

        mov     x0, x20
        blr     x19                             /* entry(userdata) */

        /* self = stashed pointer; return_to = mjs_resume_tab[self] */
        ldr     x0, [sp]
        add     sp, sp, #16
        MS_ADRP(x16, mjs_resume_tab)
        MS_ADDLO(x16, x16, mjs_resume_tab)
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
        MS_TAIL(ms_context_switch)              /* tail call: switch(self, return_to) */
6:      brk     #0x66
MS_FUNC_END(mjs_ctx_trampoline)
