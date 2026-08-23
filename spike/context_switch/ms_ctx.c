/*
 * ms_ctx.c — compile-time guards for the frozen ms_ctx_t layout consumed by
 * aarch64_switch.S. Issue mojito-async/mojito-sys#9.
 *
 * The context switch itself is pure assembly (aarch64_switch.S); this unit
 * pins the C-side layout the asm hardcodes as immediates so any header drift
 * fails at compile time instead of corrupting saved registers at runtime.
 */

#include "include/mojito_spike.h"

#include <stddef.h>

/* 12 regs + sp, all uint64_t — matches the asm's stp/ldp offset scheme. */
_Static_assert(sizeof(ms_ctx_t) == 176, "ms_ctx_t must be 12 regs + sp = 176 bytes");
_Static_assert(_Alignof(ms_ctx_t) == 8, "ms_ctx_t must be 8-byte aligned");
_Static_assert(offsetof(ms_ctx_t, regs) == 0, "regs[] must be first: asm uses base+0..88");
_Static_assert(offsetof(ms_ctx_t, sp) == 96, "sp slot must be at +96: asm immediate");

/* reg slot i => x(19+i): fp is regs[10] @80, lr is regs[11] @88. */
