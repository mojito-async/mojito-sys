/*
 * ms_context_x86_64.S — register-level backend for the frozen ms_context
 * v2 C ABI (issue #64, spec §20.2) on x86-64 System V (issue #72, spec
 * §21 #2). Darwin Mach-O AND Linux ELF via the same dual-ABI macro
 * skeleton used by ms_context_aarch64.S.
 *
 * Structural mirror of ms_context_aarch64.S (the panel-proven template):
 * the SAME per-record lifecycle state machine (v3 tail @168-199), the SAME
 * atomic-arm discipline for re-resume, the SAME loud-misuse traps, and the
 * SAME synthetic-exit trampoline.
 *
 * Host note: this backend is CROSS-ASSEMBLED on this Darwin/arm64 host
 * (clang cross-assembles x86-64); it CANNOT execute here. Behavioral proof
 * is red-excluded per spec §38.6 until a Linux/x86_64 runner exists (see
 * tests/s5/x86/run.sh).
 *
 * Save-area layout (v2 prefix pinned by _Static_asserts in ms_context.c):
 *   regs[0..11] @   0.. 95 => rbx,rbp,r12,r13,r14,r15 in [0..5]; [6..11]
 *                             zero (reserved; fp/lr slots are AArch64-only)
 *   fps[0..7]   @  96..159 => low 64 bits of xmm6..xmm13
 *   sp          @ 160
 *
 * !!! BACKEND SUPPORT STATUS — READ LOUDLY !!!: this x86-64 SysV backend is
 * NOT NativeContext-supported yet (spec §38.6). Native support requires FULL
 * 128-bit preservation of the entire SysV callee-saved SIMD set — xmm14 and
 * xmm15 are still omitted because the frozen fps bank holds only 8 low-64
 * slots (x86-64 System V diverges from AAPCS64 here: AAPCS64 needs d8-d15,
 * exactly 8 low-64 halves, whereas SysV callees own xmm6-xmm15 in FULL 128
 * bits). Until that upgrade lands along with a passing in-repo conformance
 * suite, this backend is a cross-assembled STRUCTURAL mirror only — drivers
 * must not ship production state transitions on it. Verified smoke:
 * tests/s5/x86/run.sh (assembles cleanly; behavioral rows are RED-EXCLUDED
 * UNSUPPORTED-PLATFORM until a Linux/x86_64 runner).
 * x18-equivalent: x86-64 has no platform-reserved GP register analogous
 * to AArch64 x18; nothing needs avoiding. Only temporaries rax/rcx/rdx/
 * r8-r11 are used by the backend.
 *
 * Lifecycle traps (loud int3 on GENUINE misuse only; %eax carries a
 * distinguishable marker so a debugger can tell them apart):
 *   #0x64  stack_top misaligned at make;
 *   #0x66  resume of a FINISHED context;
 *   #0x68  resume of DEAD storage (destroyed / never-initialized);
 *   #0x69  resume of a RUNNING context (concurrent re-resume);
 *   #0x6a  trampoline fall-through guard — control must NEVER fall
 *          through the switch-out (spec §22 L1173).
 *   #0x6b  restored sp slot not 16-aligned at switch time — corruption
 *          trapped BEFORE the misaligned stack is committed (mirrors the
 *          make-time #0x64 class; SysV rsp MUST be ≡0 mod 16 at entry).
 *
 * Red-zone rule (spec §21): the switch never touches memory below the
 * saved sp, so it never clobbers a callee's red zone.
 *
 * Alignment note: entry to the synthetic trampoline mirrors the SysV
 * callee convention (rsp = saved_sp - 16 after the switch's final `ret`
 * pops the parked return target), and every `call` out of the backend is
 * issued with rsp 16-byte aligned so the callee sees rsp = 0 (mod 16) at
 * its own entry. make_raw enforces stack_top 16-alignment (trap #0x64).
 */

#if defined(__APPLE__)

#define MS_SYM(name)                 _##name
#define MS_PUB(name)                 .globl _##name
#define MS_PRIV(name)                .private_extern _##name
#define MS_TEXT                      .text
#define MS_FUNC_END(name)

#elif defined(__ELF__)

#define MS_SYM(name)                 name
#define MS_PUB(name)                 .globl name ; .type name,%function
#define MS_PRIV(name)                .globl name ; .hidden name ; .type name,%function
#define MS_TEXT                      .section .text,"ax",%progbits
#define MS_FUNC_END(name)            .size name, .-name

#else
#error "ms_context_x86_64.S requires __APPLE__ (Mach-O) or __ELF__ (Linux)"
#endif

#if defined(__x86_64__)
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
/* void ms_context_switch(ms_context *from [%rdi], ms_context *to [%rsi])    */
/* Saves current callee-saved state into *from; resumes *to. Each context    */
/* record carries its own lifecycle state + return target (#66). Loud traps  */
/* on genuine misuse: resume of DEAD/RUNNING/FINISHED targets.               */
/* ------------------------------------------------------------------------ */
MS_PUB(ms_context_switch)
MS_SYM(ms_context_switch):
        /* Save callee-saved GPRs + XMM low halves + sp into *from. The
         * save happens FIRST so that capture-as-self-switch (from == to,
         * fresh zero-filled storage) becomes live here: filling sp makes
         * the snapshot resumable. The state slot is NOT part of the
         * register save — capture explicitly re-arms it on the
         * self-switch path below (capture-revives-destroyed, header F4). */
        movq    %rbx,  0(%rdi)               /* regs[0] = rbx */
        movq    %rbp,  8(%rdi)               /* regs[1] = rbp */
        movq    %r12, 16(%rdi)               /* regs[2] = r12 */
        movq    %r13, 24(%rdi)               /* regs[3] = r13 */
        movq    %r14, 32(%rdi)               /* regs[4] = r14 */
        movq    %r15, 40(%rdi)               /* regs[5] = r15 */
        /* save callee-saved XMM low halves xmm6-xmm13 into fps[0..7] */
        movq    %xmm6,  (MS_CTX_FPS_OFF)(%rdi)
        movq    %xmm7,  (MS_CTX_FPS_OFF+8)(%rdi)
        movq    %xmm8,  (MS_CTX_FPS_OFF+16)(%rdi)
        movq    %xmm9,  (MS_CTX_FPS_OFF+24)(%rdi)
        movq    %xmm10, (MS_CTX_FPS_OFF+32)(%rdi)
        movq    %xmm11, (MS_CTX_FPS_OFF+40)(%rdi)
        movq    %xmm12, (MS_CTX_FPS_OFF+48)(%rdi)
        movq    %xmm13, (MS_CTX_FPS_OFF+56)(%rdi)
        movq    %rsp,   (MS_CTX_SP_OFF)(%rdi) /* sp saved last */

        cmpq    %rdi, %rsi
        je      .Lselfswitch                    /* self-switch: capture */

        /* Target validation + ATOMIC arm (#66 per-record state machine;
         * panel P1-H2). The x86 analog of the AArch64 ldaxr/stlxrb
         * exclusive arm is `lock cmpxchgq` on the STATE slot: a hardware
         * RMW that is atomic against all other store sources. ret_to@176
         * shares STATE@168's cache line, so the ret_to write is deferred
         * until AFTER the arm succeeds (structural parity with AArch64,
         * where a same-line plain store in the exclusive window would
         * sicken stlxr forever; here it is the same cache-line hygiene —
         * the guard never writes to the armed line mid-arm). The arm
         * loop re-validates on a lost race, so resume-of-RUNNING traps
         * UNCONDITIONALLY instead of corrupting.
         * `lock cmpxchgq` compares the STATE slot against %rax (the
         * observed value): on equality it writes RUNNING (ZF=1, arm
         * won); on inequality it loads the current value into %rax and
         * clears ZF, and we re-check from the top. */
.Lrecheck:
        movq    (MS_CTX_STATE_OFF)(%rsi), %rax /* target state (full width) */
        testq   %rax, %rax
        jz      .Ltrap_dead                     /* DEAD storage: trap */
        cmpq    $MS_STATE_RUNNING, %rax
        je      .Ltrap_running                  /* re-resume RUNNING: trap */
        cmpq    $MS_STATE_FINISHED, %rax
        je      .Ltrap_finished                 /* re-resume FINISHED: trap */

        /* from->state: RUNNING -> SUSPENDED. Conditional so the
         * trampoline's post-completion switch-out (from == FINISHED)
         * never demotes FINISHED. Full-width store (clean 64-bit word
         * validation, panel P1-H1). Writes the FROM record — distinct
         * storage from the target's line, so the arm is unaffected. */
        cmpq    $MS_STATE_RUNNING, (MS_CTX_STATE_OFF)(%rdi)
        jne     .Lskip_demote
        movq    $MS_STATE_SUSPENDED, (MS_CTX_STATE_OFF)(%rdi)
.Lskip_demote:
        /* Arm to=RUNNING via lock cmpxchg (full width). A lost race
         * restarts validation at .Lrecheck: the winner made the target
         * RUNNING (or it already completed), and this caller must trap,
         * not corrupt. */
        movq    $MS_STATE_RUNNING, %rdx
        lock cmpxchgq %rdx, (MS_CTX_STATE_OFF)(%rsi)
        jne     .Lrecheck

        /* to->ret_to = from (most recent switcher of `to`). Idempotent;
         * placed AFTER the arm so no same-line plain store ever sits
         * mid-arm. */
        movq    %rdi, (MS_CTX_RETTO_OFF)(%rsi)

        /* belt+suspenders: a zeroed sp slot in a non-DEAD target is
         * corruption — trap instead of jumping through garbage. */
        cmpq    $0, (MS_CTX_SP_OFF)(%rsi)
        je      .Ltrap_dead

        /* --- restore `to` --- */
.Lrestore:
        movq    0(%rsi), %rbx
        movq    8(%rsi), %rbp
        movq    16(%rsi), %r12
        movq    24(%rsi), %r13
        movq    32(%rsi), %r14
        movq    40(%rsi), %r15
        movq    (MS_CTX_FPS_OFF)(%rsi), %xmm6
        movq    (MS_CTX_FPS_OFF+8)(%rsi), %xmm7
        movq    (MS_CTX_FPS_OFF+16)(%rsi), %xmm8
        movq    (MS_CTX_FPS_OFF+24)(%rsi), %xmm9
        movq    (MS_CTX_FPS_OFF+32)(%rsi), %xmm10
        movq    (MS_CTX_FPS_OFF+40)(%rsi), %xmm11
        /* restored-sp 16-alignment trap (#0x6b, mirroring make #0x64): a
         * misaligned sp slot means the caller's make/capture stack is
         * corrupt — SysV requires rsp ≡ 0 (mod 16) at callee entry, and
         * the trampoline prologue + every `call` rely on the invariant
         * (see the alignment note above). Test the low 4 bits BEFORE the
         * mov that commits it; int3 on violation so a debugger can catch
         * it at the source instead of inheriting a misaligned stack. */
        movq    (MS_CTX_SP_OFF)(%rsi), %rax    /* load saved sp to test */
        testq   $15, %rax
        jnz     .Ltrap_unaligned_sp             /* rsp not 16-aligned: trap */
        movq    %rax, %rsp                      /* sp last; ret pops target */
        ret

        /* Self-switch (ms_context_capture): the just-saved snapshot IS
         * the resumable state, so arm the record as SUSPENDED regardless
         * of its prior state — this REVIVES destroyed (DEAD) storage and
         * overwrites any live snapshot (header F4/capture contracts) —
         * then resumes right here. */
.Lselfswitch:
        movq    $MS_STATE_SUSPENDED, (MS_CTX_STATE_OFF)(%rsi)
        jmp     .Lrestore

        /* Loud traps with distinguishable %eax markers */
.Ltrap_finished:
        movl    $0x66, %eax
        int3                                    /* resume of FINISHED ctx */
.Ltrap_dead:
        movl    $0x68, %eax
        int3                                    /* resume of DEAD/poisoned */
.Ltrap_running:
        movl    $0x69, %eax
        int3                                    /* re-resume of RUNNING ctx */
.Ltrap_unaligned_sp:
        movl    $0x6b, %eax
        int3                                    /* restored sp not 16-aligned */
MS_FUNC_END(ms_context_switch)

/* ------------------------------------------------------------------------ */
/* void mjs__ctx_make_raw(ms_context *ctx [%rdi], void *stack_top [%rsi],    */
/*                        ms_context_entry entry [%rdx],                    */
/*                        void *userdata [%rcx])                            */
/* Dylib-private helper behind ms_context_init's validation. Synthesizes a   */
/* resumed state: first switch lands on the exit trampoline with             */
/* rsp = stack_top - 16 (16-aligned; misalignment traps), where make has     */
/* parked the trampoline's return target AND the self pointer (make's own    */
/* frame). Arms the lifecycle tail: EMPTY, no return target, no finish hook  */
/* (#66).                                                                    */
/* ------------------------------------------------------------------------ */
MS_PRIV(mjs__ctx_make_raw)
MS_SYM(mjs__ctx_make_raw):
        testq   $15, %rsi
        jnz     .Ltrap_misalign                /* stack_top misaligned */
        leaq    -16(%rsi), %r8                 /* make frame = stack_top-16 */
        /* make's frame: [r8]   = return target (trampoline) so the first
         * switch's final `ret` lands in the trampoline with rsp advancing
         * to stack_top-8; [r8+8] = self (ctx) read by the trampoline at
         * entry (where [rsp] == the stashed self on the very first frame). */
        leaq    MS_SYM(mjs_ctx_trampoline)(%rip), %rax
        movq    %rax, 0(%r8)                   /* [stack_top-16] = trampoline */
        movq    %rdi, 8(%r8)                   /* [stack_top-8]  = self */
        movq    %r8, (MS_CTX_SP_OFF)(%rdi)     /* sp slot = stack_top - 16 */
        /* regs: rbx=entry, rbp=0, r12=userdata, r13-r15=0 */
        movq    %rdx, 0(%rdi)                  /* regs[0] = rbx = entry */
        movq    %rcx, 16(%rdi)                 /* regs[2] = r12 = userdata */
        movq    $0, 8(%rdi)                    /* regs[1] = rbp */
        movq    $0, 24(%rdi)                   /* regs[3] = r13 */
        movq    $0, 32(%rdi)                   /* regs[4] = r14 */
        movq    $0, 40(%rdi)                   /* regs[5] = r15 */
        /* fps zero */
        pxor    %xmm0, %xmm0
        movq    %xmm0, (MS_CTX_FPS_OFF)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+8)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+16)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+24)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+32)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+40)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+48)(%rdi)
        movq    %xmm0, (MS_CTX_FPS_OFF+56)(%rdi)
        /* lifecycle tail: EMPTY, no target, no hook */
        movq    $0, (MS_CTX_RETTO_OFF)(%rdi)
        movq    $0, (MS_CTX_FINCB_OFF)(%rdi)
        movq    $0, (MS_CTX_FINUD_OFF)(%rdi)
        movq    $MS_STATE_EMPTY, (MS_CTX_STATE_OFF)(%rdi) /* armed, never run */
        ret
.Ltrap_misalign:
        movl    $0x64, %eax
        int3                                    /* stack_top not 16-aligned */
MS_FUNC_END(mjs__ctx_make_raw)

/* ------------------------------------------------------------------------ */
/* Exit trampoline (private): entered INDIRECTLY — via the first switch's    */
/* final `ret` — with rbx = entry, r12 = userdata and [rsp] = self. Spec     */
/* §22 flow (L1153-1173): calls                                              */
/* entry(userdata) with userdata passed through UNMODIFIED, runs the         */
/* completion stage (finish hook exactly once, then state = FINISHED), then  */
/* switches out PERMANENTLY to the context's own recorded return target.     */
/* The switch-out is followed by a fall-through guard (int3 #0x6a) — a       */
/* synthetic stack never falls through an invalid return address. Resuming   */
/* an already-FINISHED context traps in ms_context_switch (#0x66).           */
/* ------------------------------------------------------------------------ */
MS_PRIV(mjs_ctx_trampoline)
MS_SYM(mjs_ctx_trampoline):
        /* entry: rsp = stack_top-8 (≡8 mod 16, SysV callee convention),
         * [rsp] = self. Prologue moves rsp to 16-alignment and parks
         * self at 8(%rbp). */
        pushq   %rbp                            /* rsp: S8 -> S16 (≡0 mod16) */
        movq    %rsp, %rbp
        movq    %r12, %rdi                      /* arg0 = userdata (UNMODIFIED) */
        callq   *%rbx                           /* entry(userdata), rsp ≡0 ✓ */

        /* Completion stage (#66): fire the registered finish hook EXACTLY
         * once — this pass runs once per context lifetime — before the
         * permanent switch-out. */
        movq    8(%rbp), %rbx                   /* rbx = self */
        movq    (MS_CTX_FINCB_OFF)(%rbx), %rax  /* finish_cb */
        testq   %rax, %rax
        jz      .Lfinished
        movq    (MS_CTX_FINUD_OFF)(%rbx), %rdi  /* finish_userdata */
        callq   *%rax                           /* finish_cb(finish_ud) */
.Lfinished:
        movq    $MS_STATE_FINISHED, (MS_CTX_STATE_OFF)(%rbx)
        movq    %rbx, %rdi                      /* from = self */
        movq    (MS_CTX_RETTO_OFF)(%rbx), %rsi  /* to = permanent target */
        callq   MS_SYM(ms_context_switch)       /* never returns to us */
        /* fall-through guard (#0x6a): control must NEVER reach here */
        movl    $0x6a, %eax
        int3
MS_FUNC_END(mjs_ctx_trampoline)
#endif /* __x86_64__ */