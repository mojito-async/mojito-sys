/*
 * aarch64_switch.S — ms_ctx_make / ms_ctx_switch for Apple arm64 (AAPCS64).
 *
 * Owns (issue mojito-async/mojito-sys#9):
 *   - ms_ctx_switch(from, to): save x19-x28, fp(x29), lr(x30) into
 *     from->regs[0..11], sp into from->sp; restore the reverse order from
 *     `to` and return through its saved lr. x18 is never written.
 *   - ms_ctx_make(ctx, stack_top, entry, userdata): synthesize a resumed
 *     state so the first switch lands on a trampoline that tail-calls
 *     entry(userdata) with sp == stack_top (16-byte aligned), and switches
 *     back to the resuming context after entry returns.
 *
 * This is the RED commit: no ms_ctx_* symbols are defined yet, so any
 * link against this object must fail with undefined symbols.
 */

.section __TEXT,__text,regular,pure_instructions
