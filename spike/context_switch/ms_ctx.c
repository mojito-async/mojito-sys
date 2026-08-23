/*
 * ms_ctx.c — compile-time guards for the frozen ms_ctx_t layout consumed by
 * aarch64_switch.S (issue mojito-async/mojito-sys#9).
 *
 * Guards (landed with the implementation commit):
 *   sizeof(ms_ctx_t) == 176   (12 regs + sp, all uint64_t)
 *   offsetof(ms_ctx_t, regs) == 0
 *   offsetof(ms_ctx_t, sp)   == 96
 *
 * This is the RED commit: the file compiles to an empty translation unit;
 * ms_ctx_make/ms_ctx_switch are absent by design until the green commit.
 */
